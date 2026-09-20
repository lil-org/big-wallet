// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    pushArrayNormally,
    MapConstructor,
    TypeErrorConstructor,
    getMapEntry,
    setMapEntry,
} from "./intrinsics";

const deleteMapEntryNormally = Map.prototype.delete;
const forEachMapNormally = Map.prototype.forEach;
const setPrototypeOfNormally = Object.setPrototypeOf;
const ErrorConstructor = Error;
const RangeErrorConstructor = RangeError;
const defaultMaximumLoadingOperations = 64;
const maximumWireId = Number.MAX_SAFE_INTEGER;

function operationQueue() {
    const queue = [];
    setPrototypeOfNormally(queue, null);
    return queue;
}

function deleteMapEntry(map, key) {
    applyFunction(deleteMapEntryNormally, map, [key]);
}

class OperationRuntime {

    #generation;
    #nextWireId = 1;
    #operations = new MapConstructor;
    #phase = "loading";
    #queue = operationQueue();
    #loadingAdmissionCount = 0;
    #loadingError;
    #maximumLoadingOperations;
    #retirementError;
    #wireIdStep = 1;

    constructor(generation, {
        firstWireId = 1,
        maximumLoadingOperations = defaultMaximumLoadingOperations,
        wireIdStep = 1,
    } = {}) {
        if (!Number.isSafeInteger(firstWireId) || firstWireId <= 0 ||
            !Number.isSafeInteger(maximumLoadingOperations) ||
            maximumLoadingOperations <= 0 ||
            !Number.isSafeInteger(wireIdStep) || wireIdStep <= 0) {
            throw new TypeErrorConstructor("Invalid operation runtime options");
        }
        this.#generation = generation;
        this.#maximumLoadingOperations = maximumLoadingOperations;
        this.#nextWireId = firstWireId;
        this.#wireIdStep = wireIdStep;
    }

    static get maximumLoadingOperations() {
        return defaultMaximumLoadingOperations;
    }

    get generation() {
        return this.#generation;
    }

    get phase() {
        return this.#phase;
    }

    register({originalId, payload, metadata} = {}) {
        if (this.#phase === "failed") { throw this.#loadingError; }
        if (this.#phase === "retired") {
            throw this.#retirementError ||
                new ErrorConstructor("Operation runtime retired");
        }
        if (this.#nextWireId > maximumWireId) {
            throw new RangeErrorConstructor("Operation wire ID space exhausted");
        }
        const wireId = this.#nextWireId;
        this.#nextWireId = wireId > maximumWireId - this.#wireIdStep
            ? maximumWireId + 1
            : wireId + this.#wireIdStep;
        let resolvePromise;
        let rejectPromise;
        const promise = new Promise((resolve, reject) => {
            resolvePromise = resolve;
            rejectPromise = reject;
        });
        const record = {
            __proto__: null,
            generation: this.#generation,
            metadata,
            originalId,
            payload,
            promise,
            wireId,
            dispatching: false,
            queued: false,
            rejectPromise,
            resolvePromise,
        };
        setMapEntry(this.#operations, wireId, record);
        return record;
    }

    owns(record) {
        return !!record && getMapEntry(this.#operations, record.wireId) === record;
    }

    operation(wireId) {
        return getMapEntry(this.#operations, wireId);
    }

    enqueue(record) {
        if (this.#phase === "ready" || this.#phase === "retired" ||
            this.#phase === "failed") {
            return false;
        }
        if (!this.owns(record) || record.queued || record.dispatching) { return false; }
        if (this.#loadingAdmissionCount >= this.#maximumLoadingOperations) {
            return false;
        }
        this.#loadingAdmissionCount += 1;
        record.queued = true;
        applyFunction(pushArrayNormally, this.#queue, [record]);
        return true;
    }

    drain(dispatch) {
        if (typeof dispatch !== "function") {
            throw new TypeErrorConstructor("Operation dispatch must be a function");
        }
        if (this.#phase === "retired" || this.#phase === "ready" ||
            this.#phase === "draining") {
            return 0;
        }
        this.#phase = "draining";
        this.#loadingError = undefined;
        let dispatched = 0;
        let drainingQueue = this.#queue;
        let queueIndex = 0;
        try {
            while (this.#phase === "draining") {
                if (drainingQueue !== this.#queue) {
                    drainingQueue = this.#queue;
                    queueIndex = 0;
                }
                if (queueIndex >= drainingQueue.length) { break; }
                const record = drainingQueue[queueIndex];
                drainingQueue[queueIndex] = null;
                queueIndex += 1;
                if (!this.owns(record) || !record.queued) { continue; }
                record.queued = false;
                record.dispatching = true;
                try {
                    dispatch(record);
                    dispatched += 1;
                } catch (error) {
                    this.reject(record, error);
                } finally {
                    record.dispatching = false;
                }
            }
        } finally {
            this.#queue = operationQueue();
            this.#loadingAdmissionCount = 0;
            if (this.#phase === "draining") {
                this.#phase = "ready";
            }
        }
        return dispatched;
    }

    resolve(record, value) {
        const settlement = this.#take(record);
        if (!settlement) { return false; }
        settlement.resolvePromise(value);
        return true;
    }

    reject(record, error) {
        const settlement = this.#take(record);
        if (!settlement) { return false; }
        settlement.rejectPromise(error);
        return true;
    }

    rejectAll(error) {
        const entries = operationQueue();
        applyFunction(forEachMapNormally, this.#operations, [entry => {
            applyFunction(pushArrayNormally, entries, [entry]);
        }]);
        this.#operations = new MapConstructor;
        this.#queue = operationQueue();
        this.#loadingAdmissionCount = 0;
        for (let index = 0; index < entries.length; index += 1) {
            entries[index].dispatching = false;
            entries[index].queued = false;
        }
        for (let index = 0; index < entries.length; index += 1) {
            entries[index].rejectPromise(error);
        }
        return entries.length;
    }

    failLoading(error) {
        if (this.#phase !== "loading") { return false; }
        this.#phase = "failed";
        this.#loadingError = error;
        this.rejectAll(error);
        return true;
    }

    retire(error = new ErrorConstructor("Operation runtime retired")) {
        if (this.#phase === "retired") { return 0; }
        this.#phase = "retired";
        this.#retirementError = error;
        return this.rejectAll(error);
    }

    #take(record) {
        if (!this.owns(record)) { return null; }
        deleteMapEntry(this.#operations, record.wireId);
        record.dispatching = false;
        record.queued = false;
        return record;
    }
}

export { OperationRuntime };
export default OperationRuntime;
