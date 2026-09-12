// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    createObjectNormally,
    definePropertyNormally,
    freezeObjectNormally,
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

function trustedOutboundRecord(values) {
    const record = createObjectNormally(null);
    const names = getOwnPropertyNamesNormally(values);
    for (let index = 0; index < names.length; index += 1) {
        const name = names[index];
        const descriptor = getOwnPropertyDescriptorNormally(values, name);
        if (descriptor.enumerable && "value" in descriptor) {
            definePropertyNormally(record, name, {
                __proto__: null,
                enumerable: true,
                value: descriptor.value,
            });
        }
    }
    return freezeObjectNormally(record);
}

function trustedOutboundArray(values) {
    const array = [];
    for (let index = 0; index < values.length; index += 1) {
        definePropertyNormally(array, index, {
            __proto__: null,
            enumerable: true,
            value: getOwnPropertyDescriptorNormally(values, index)?.value,
        });
    }
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
