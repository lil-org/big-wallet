// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    definePropertyNormally,
    getOwnPropertyDescriptorNormally,
    TypeErrorConstructor,
} from "./intrinsics";

const getOwnPropertyNamesNormally = Object.getOwnPropertyNames;
const parseJSONNormally = JSON.parse;
const stringifyJSONNormally = JSON.stringify;

function neutralizeSnapshot(value) {
    if (!value || typeof value !== "object") { return value; }
    const names = applyFunction(getOwnPropertyNamesNormally, Object, [value]);
    for (let index = 0; index < names.length; index += 1) {
        const descriptor = applyFunction(
            getOwnPropertyDescriptorNormally,
            Object,
            [value, names[index]]
        );
        if (descriptor && "value" in descriptor) {
            neutralizeSnapshot(descriptor.value);
        }
    }
    if (!applyFunction(
        getOwnPropertyDescriptorNormally,
        Object,
        [value, "toJSON"]
    )) {
        applyFunction(definePropertyNormally, Object, [value, "toJSON", {
            configurable: true,
            enumerable: false,
            value: undefined,
            writable: true,
        }]);
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

export { nativeJSONClone, outboundDataSnapshot, outboundJSONSerialize };
