"use strict";

export const applyFunction = Reflect.apply;
export const createObjectNormally = Object.create;
export const definePropertyNormally = Object.defineProperty;
export const freezeObjectNormally = Object.freeze;
export const getOwnPropertyDescriptorNormally = Object.getOwnPropertyDescriptor;
export const isArrayNormally = Array.isArray;
export const isSafeIntegerNormally = Number.isSafeInteger;
export const pushArrayNormally = Array.prototype.push;
export const MapConstructor = Map;
export const TypeErrorConstructor = TypeError;

const hasOwnPropertyNormally = Object.prototype.hasOwnProperty;
const getMapEntryNormally = Map.prototype.get;
const setMapEntryNormally = Map.prototype.set;
const getWeakMapValueNormally = WeakMap.prototype.get;
const setWeakMapValueNormally = WeakMap.prototype.set;

export function hasOwnProperty(object, name) {
    return applyFunction(hasOwnPropertyNormally, object, [name]);
}

export function getMapEntry(map, key) {
    return applyFunction(getMapEntryNormally, map, [key]);
}

export function setMapEntry(map, key, value) {
    applyFunction(setMapEntryNormally, map, [key, value]);
}

export function getWeakMapValue(map, key) {
    return applyFunction(getWeakMapValueNormally, map, [key]);
}

export function setWeakMapValue(map, key, value) {
    applyFunction(setWeakMapValueNormally, map, [key, value]);
}
