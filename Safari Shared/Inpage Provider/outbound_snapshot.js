// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    definePropertyNormally,
    freezeObjectNormally,
    hasOwnProperty,
    TypeErrorConstructor,
} from "./intrinsics";

const objectKeysNormally = Object.keys;
const parseJSONNormally = JSON.parse;
const stringifyJSONNormally = JSON.stringify;

function neutralizeSnapshot(value) {
    if (!value || typeof value !== "object") { return value; }
    const names = objectKeysNormally(value);
    for (let index = 0; index < names.length; index += 1) {
        neutralizeSnapshot(value[names[index]]);
    }
    if (!hasOwnProperty(value, "toJSON")) {
        definePropertyNormally(value, "toJSON", {
            __proto__: null,
            configurable: true,
            enumerable: false,
            value: undefined,
            writable: true,
        });
    }
    return value;
}

function outboundJSONSerialize(value) {
    const serialized = applyFunction(
        stringifyJSONNormally,
        undefined,
        [value]
    );
    if (typeof serialized !== "string") {
        throw new TypeErrorConstructor("Unsupported outbound value");
    }
    return serialized;
}

function nativeJSONClone(value) {
    return applyFunction(
        parseJSONNormally,
        undefined,
        [outboundJSONSerialize(value)]
    );
}

function outboundDataSnapshot(value) {
    return neutralizeSnapshot(nativeJSONClone(value));
}

function trustedOutboundRecord(values) {
    return freezeObjectNormally({__proto__: null, ...values});
}

function trustedOutboundArray(values) {
    const array = [...values];
    definePropertyNormally(array, "toJSON", {__proto__: null, value: undefined});
    return freezeObjectNormally(array);
}

export {
    nativeJSONClone,
    outboundDataSnapshot,
    outboundJSONSerialize,
    trustedOutboundArray,
    trustedOutboundRecord,
};
