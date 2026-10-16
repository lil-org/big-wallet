"use strict";

export const applyFunction = Reflect.apply;
export const createObjectNormally = Object.create;
export const definePropertyNormally = Object.defineProperty;
export const freezeObjectNormally = Object.freeze;
export const getOwnPropertyDescriptorNormally = Object.getOwnPropertyDescriptor;
export const isArrayNormally = Array.isArray;
export const isSafeIntegerNormally = Number.isSafeInteger;
export const TypeErrorConstructor = TypeError;

const hasOwnPropertyNormally = Object.prototype.hasOwnProperty;

export function hasOwnProperty(object, name) {
    return applyFunction(hasOwnPropertyNormally, object, [name]);
}
