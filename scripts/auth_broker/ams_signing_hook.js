/*
 * Frida prototype for the vPhone host-auth donation path.
 *
 * Attach with:
 *   frida -H 127.0.0.1:27042 -f com.apple.stocks -l scripts/auth_broker/ams_signing_hook.js
 *
 * The hook observes global AppleMediaServices signing chokepoints and forwards a
 * sanitized event to the host VPhoneAuthBroker over guest→host vsock port 1338.
 */

'use strict';

const AF_VSOCK = 40;
const AF_INET = 2;
const SOCK_STREAM = 1;
const VMADDR_CID_HOST = 2;
const AUTH_BROKER_PORT = 1338;
const AUTH_BROKER_LOCAL_PORT = 17338;

function log(message) {
  console.log('[ams-hook] ' + message);
}

function exportByName(name) {
  try {
    return Module.getGlobalExportByName(name);
  } catch (_) {
    return null;
  }
}

const socketPtr = exportByName('socket');
const connectPtr = exportByName('connect');
const closePtr = exportByName('close');
const readPtr = exportByName('read');
const writePtr = exportByName('write');

const socketFn = socketPtr ? new NativeFunction(socketPtr, 'int', ['int', 'int', 'int']) : null;
const connectFn = connectPtr ? new NativeFunction(connectPtr, 'int', ['int', 'pointer', 'int']) : null;
const closeFn = closePtr ? new NativeFunction(closePtr, 'int', ['int']) : null;
const readFn = readPtr ? new NativeFunction(readPtr, 'long', ['int', 'pointer', 'ulong']) : null;
const writeFn = writePtr ? new NativeFunction(writePtr, 'long', ['int', 'pointer', 'ulong']) : null;

function writeFully(fd, bytes) {
  const data = Memory.alloc(bytes.length);
  for (let i = 0; i < bytes.length; i++) data.add(i).writeU8(bytes[i]);
  let offset = 0;
  while (offset < bytes.length) {
    const n = Number(writeFn(fd, data.add(offset), bytes.length - offset));
    if (n <= 0) return false;
    offset += n;
  }
  return true;
}

function readFully(fd, length) {
  const data = Memory.alloc(length);
  let offset = 0;
  while (offset < length) {
    const n = Number(readFn(fd, data.add(offset), length - offset));
    if (n <= 0) return null;
    offset += n;
  }
  const out = [];
  for (let i = 0; i < length; i++) out.push(data.add(i).readU8());
  return out;
}

function utf8Bytes(string) {
  const out = [];
  for (const byte of unescape(encodeURIComponent(string)).split('').map(c => c.charCodeAt(0))) {
    out.push(byte);
  }
  return out;
}

function bytesToString(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return decodeURIComponent(escape(s));
}

function sendBroker(kind, payload) {
  if (!socketFn || !connectFn || !writeFn || !readFn || !closeFn) {
    log('native socket functions unavailable');
    return null;
  }

  const fd = socketFn(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    log('socket failed');
    return null;
  }

  const addr = Memory.alloc(16);
  addr.writeU8(16);
  addr.add(1).writeU8(AF_INET);
  addr.add(2).writeU8((AUTH_BROKER_LOCAL_PORT >>> 8) & 0xff);
  addr.add(3).writeU8(AUTH_BROKER_LOCAL_PORT & 0xff);
  addr.add(4).writeU8(127);
  addr.add(5).writeU8(0);
  addr.add(6).writeU8(0);
  addr.add(7).writeU8(1);
  for (let i = 8; i < 16; i++) addr.add(i).writeU8(0);

  if (connectFn(fd, addr, 16) !== 0) {
    closeFn(fd);
    log('local relay connect failed; is the updated vphoned running?');
    return null;
  }

  const request = JSON.stringify({
    v: 1,
    t: 'auth_broker_request',
    kind,
    payload,
  });
  const body = utf8Bytes(request);
  const frame = [
    (body.length >>> 24) & 0xff,
    (body.length >>> 16) & 0xff,
    (body.length >>> 8) & 0xff,
    body.length & 0xff,
  ].concat(body);

  if (!writeFully(fd, frame)) {
    closeFn(fd);
    log('broker write failed');
    return null;
  }

  const header = readFully(fd, 4);
  if (header === null) {
    closeFn(fd);
    log('broker response header missing');
    return null;
  }
  const length = ((header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3]) >>> 0;
  const responseBytes = readFully(fd, length);
  closeFn(fd);
  if (responseBytes === null) {
    log('broker response body missing');
    return null;
  }
  return JSON.parse(bytesToString(responseBytes));
}

function safeString(value) {
  try {
    if (value === null || value === undefined || value.isNull && value.isNull()) return null;
    return ObjC.Object(value).toString();
  } catch (_) {
    return String(value);
  }
}

function requestSummary(requestPtr) {
  try {
    const request = ObjC.Object(requestPtr);
    const url = request.URL();
    const headers = request.allHTTPHeaderFields();
    const body = request.HTTPBody();
    return {
      url: url.isNull() ? null : url.absoluteString().toString(),
      method: request.HTTPMethod().toString(),
      headers: headers.isNull() ? [] : ObjC.Object(headers).allKeys().toString(),
      body: dataSummary(body),
    };
  } catch (e) {
    return { error: String(e) };
  }
}

function dataSummary(dataPtr) {
  try {
    if (dataPtr.isNull()) return null;
    const data = ObjC.Object(dataPtr);
    const length = data.length().valueOf();
    const bytes = data.bytes();
    const previewLength = Math.min(length, 64);
    let previewHex = '';
    for (let i = 0; i < previewLength; i++) {
      const byte = bytes.add(i).readU8();
      previewHex += ('0' + byte.toString(16)).slice(-2);
    }
    return {
      length,
      previewHex,
      previewTruncated: length > previewLength,
    };
  } catch (_) {
    return null;
  }
}

function hookClassMethod(className, selector, callback) {
  try {
    const klass = ObjC.classes[className];
    if (!klass || !klass[selector]) {
      log('missing ' + className + ' ' + selector);
      return;
    }
    Interceptor.attach(klass[selector].implementation, callback);
    log('hooked ' + className + ' ' + selector);
  } catch (e) {
    log('hook failed ' + className + ' ' + selector + ': ' + e);
  }
}

function brokerKindForPayload(payload) {
  const requestURL = payload.request && payload.request.url ? payload.request.url : '';
  return requestURL.indexOf('https://fpinit.itunes.apple.com/v1/signSapSetup') === 0
    ? 'ams_sign_sap_setup'
    : 'ams_signing_probe';
}

function emitSigningProbe(selector, payload) {
  payload.selector = selector;
  payload.process = Process.id;
  payload.processName = Process.name || 'unknown';
  log(selector + ' payload=' + JSON.stringify(payload));
  const kind = brokerKindForPayload(payload);
  const response = sendBroker(kind, payload);
  log(selector + ' broker=' + JSON.stringify(response));
  return response;
}

function responseHeaders(response) {
  if (!response || !response.ok || !response.data || !response.data.headers) return null;
  return response.data.headers;
}

function applyHeadersToRequest(requestPtr, headers, selector) {
  try {
    if (!headers || requestPtr.isNull()) return false;
    const request = ObjC.Object(requestPtr);
    if (!request.respondsToSelector_(ObjC.selector('setValue:forHTTPHeaderField:'))) {
      log(selector + ' cannot inject headers; request is not mutable');
      return false;
    }
    let applied = 0;
    Object.keys(headers).forEach(function (field) {
      const value = headers[field];
      if (value === null || value === undefined) return;
      request.setValue_forHTTPHeaderField_(String(value), String(field));
      applied += 1;
    });
    log(selector + ' injected_headers=' + applied);
    return applied > 0;
  } catch (e) {
    log(selector + ' header injection failed=' + e);
    return false;
  }
}

function applyBrokerResponseToRequest(response, requestPtr, selector) {
  return applyHeadersToRequest(requestPtr, responseHeaders(response), selector);
}

function replaceReturnString(retval, value, selector) {
  try {
    if (value === null || value === undefined) return false;
    const string = ObjC.classes.NSString.stringWithString_(String(value));
    retval.replace(string);
    log(selector + ' replaced_return_string=true');
    return true;
  } catch (e) {
    log(selector + ' return replacement failed=' + e);
    return false;
  }
}

hookClassMethod('AMSURLRequestDecoration', '+ addMescalHeaderToRequest:type:bag:logKey:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSURLRequestDecoration.addMescalHeader', {
      request: requestSummary(args[2]),
      type: safeString(args[3]),
      logKey: safeString(args[5]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSURLRequestDecoration.addMescalHeader');
  },
});

hookClassMethod('AMSURLRequestDecoration', '+ addAbsintheHeadersToRequest:buyParams:bag:shouldUseRemoteSigningIfAvailable:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSURLRequestDecoration.addAbsintheHeaders', {
      request: requestSummary(args[2]),
      buyParams: safeString(args[3]),
      shouldUseRemoteSigningIfAvailable: Number(args[5]) !== 0,
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSURLRequestDecoration.addAbsintheHeaders');
  },
});

hookClassMethod('AMSAbsinthe', '+ headersForRequest:buyParams:bag:', {
  onEnter(args) {
    emitSigningProbe('AMSAbsinthe.headersForRequest', {
      request: requestSummary(args[2]),
      buyParams: safeString(args[3]),
    });
  },
});

hookClassMethod('AMSAbsinthe', '+ _dataToSignFromRequest:bagDefinition:', {
  onEnter(args) {
    emitSigningProbe('AMSAbsinthe.dataToSignFromRequest', {
      request: requestSummary(args[2]),
      bagDefinition: safeString(args[3]),
    });
  },
});

hookClassMethod('AMSAbsinthe', '+ _signingDataFromRequest:buyParams:definitions:', {
  onEnter(args) {
    emitSigningProbe('AMSAbsinthe.signingDataFromRequest', {
      request: requestSummary(args[2]),
      buyParams: safeString(args[3]),
      definitions: safeString(args[4]),
    });
  },
});

hookClassMethod('AMSMescal', '+ signatureUsingRequest:type:bag:error:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSMescal.signatureUsingRequest', {
      request: requestSummary(args[2]),
      type: safeString(args[3]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSMescal.signatureUsingRequest');
  },
});

hookClassMethod('AMSMescal', '+ signatureUsingRequest:type:bagContract:error:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSMescal.signatureUsingRequestBagContract', {
      request: requestSummary(args[2]),
      type: safeString(args[3]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSMescal.signatureUsingRequestBagContract');
  },
});

hookClassMethod('AMSMescal', '+ signatureUsingRequest:type:bagContract:logKey:error:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSMescal.signatureUsingRequestBagContractLogKey', {
      request: requestSummary(args[2]),
      type: safeString(args[3]),
      logKey: safeString(args[5]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSMescal.signatureUsingRequestBagContractLogKey');
  },
});

hookClassMethod('AMSMescal', '+ signatureFromData:type:bag:error:', {
  onEnter(args) {
    this.brokerResponse = emitSigningProbe('AMSMescal.signatureFromData', {
      data: dataSummary(args[2]),
      type: safeString(args[3]),
    });
  },
  onLeave(retval) {
    const signature = this.brokerResponse && this.brokerResponse.ok && this.brokerResponse.data
      ? this.brokerResponse.data.mescalSignature
      : null;
    replaceReturnString(retval, signature, 'AMSMescal.signatureFromData');
  },
});

hookClassMethod('AMSMescal', '+ signaturePromiseFromRequest:type:bag:', {
  onEnter(args) {
    emitSigningProbe('AMSMescal.signaturePromiseFromRequest', {
      request: requestSummary(args[2]),
      type: safeString(args[3]),
    });
  },
});

hookClassMethod('AMSAbsintheSession', '- signData:bag:error:', {
  onEnter(args) {
    emitSigningProbe('AMSAbsintheSession.signData', {
      data: dataSummary(args[2]),
      bag: safeString(args[3]),
    });
  },
});

hookClassMethod('AMSMescalSession', '- signData:bag:error:', {
  onEnter(args) {
    emitSigningProbe('AMSMescalSession.signData', {
      data: dataSummary(args[2]),
      bag: safeString(args[3]),
    });
  },
});

hookClassMethod('AMSMescalFairPlay', '- signData:error:', {
  onEnter(args) {
    emitSigningProbe('AMSMescalFairPlay.signData', {
      data: dataSummary(args[2]),
    });
  },
});

hookClassMethod('AMSURLRequestEncoder', '- requestByEncodingRequest:parameters:error:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSURLRequestEncoder.requestByEncodingRequest', {
      request: requestSummary(args[2]),
      parameters: safeString(args[3]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSURLRequestEncoder.requestByEncodingRequest');
  },
});

hookClassMethod('AMSURLRequestEncoder', '- requestByEncodingRequest:parameters:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSURLRequestEncoder.requestByEncodingRequestNoError', {
      request: requestSummary(args[2]),
      parameters: safeString(args[3]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSURLRequestEncoder.requestByEncodingRequestNoError');
  },
});

hookClassMethod('AMSURLRequestEncoder', '- requestByEncodingRequestAndReturnSigningErrors:parameters:', {
  onEnter(args) {
    const response = emitSigningProbe('AMSURLRequestEncoder.requestByEncodingRequestAndReturnSigningErrors', {
      request: requestSummary(args[2]),
      parameters: safeString(args[3]),
    });
    applyBrokerResponseToRequest(response, args[2], 'AMSURLRequestEncoder.requestByEncodingRequestAndReturnSigningErrors');
  },
});

hookClassMethod('AMSURLRequestEncoder', '- requestWithMethod:URL:parameters:error:', {
  onEnter(args) {
    emitSigningProbe('AMSURLRequestEncoder.requestWithMethodURL', {
      method: safeString(args[2]),
      url: safeString(args[3]),
      parameters: safeString(args[4]),
    });
  },
});

hookClassMethod('AMSURLSession', '- _prepareRequest:logUUID:', {
  onEnter(args) {
    emitSigningProbe('AMSURLSession.prepareRequest', {
      request: requestSummary(args[2]),
      logUUID: safeString(args[3]),
    });
  },
});

log('AMS signing hook installed');
emitSigningProbe('hook.startup', {
  note: 'broker connectivity probe before AMS signing methods fire',
});
setInterval(function () {}, 1000);
