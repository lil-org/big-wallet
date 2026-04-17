// ∅ 2026 lil org

"use strict";

import { Buffer } from "buffer";

const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const base = alphabet.length;
const leader = alphabet.charAt(0);
const alphabetMap = {};

for (let index = 0; index < alphabet.length; index++) {
    alphabetMap[alphabet[index]] = index;
}

class Base58 {

    static encode(source) {
        const bytes = Buffer.from(source);
        if (bytes.length === 0) {
            return "";
        }

        let zeroes = 0;
        let begin = 0;
        while (begin < bytes.length && bytes[begin] === 0) {
            begin += 1;
            zeroes += 1;
        }

        const size = (((bytes.length - begin) * 138) / 100 + 1) >>> 0;
        const encoded = new Uint8Array(size);
        let length = 0;

        while (begin < bytes.length) {
            let carry = bytes[begin];
            let index = 0;

            for (let position = size - 1; (carry !== 0 || index < length) && position >= 0; position--, index++) {
                carry += 256 * encoded[position];
                encoded[position] = carry % base;
                carry = (carry / base) | 0;
            }

            length = index;
            begin += 1;
        }

        let position = size - length;
        while (position < size && encoded[position] === 0) {
            position += 1;
        }

        let result = leader.repeat(zeroes);
        while (position < size) {
            result += alphabet[encoded[position]];
            position += 1;
        }

        return result;
    }

    static decode(value) {
        if (typeof value !== "string") {
            throw new TypeError("Expected a base58 string");
        }

        if (value.length === 0) {
            return Buffer.from([]);
        }

        let zeroes = 0;
        let begin = 0;
        while (begin < value.length && value[begin] === leader) {
            begin += 1;
            zeroes += 1;
        }

        const size = (((value.length - begin) * 733) / 1000 + 1) >>> 0;
        const decoded = new Uint8Array(size);
        let length = 0;

        while (begin < value.length) {
            const char = value[begin];
            if (!(char in alphabetMap)) {
                throw new Error("Non-base58 character");
            }

            let carry = alphabetMap[char];
            let index = 0;

            for (let position = size - 1; (carry !== 0 || index < length) && position >= 0; position--, index++) {
                carry += base * decoded[position];
                decoded[position] = carry % 256;
                carry = (carry / 256) | 0;
            }

            length = index;
            begin += 1;
        }

        let position = size - length;
        while (position < size && decoded[position] === 0) {
            position += 1;
        }

        const result = Buffer.alloc(zeroes + (size - position));
        result.fill(0, 0, zeroes);

        let offset = zeroes;
        while (position < size) {
            result[offset] = decoded[position];
            offset += 1;
            position += 1;
        }

        return result;
    }

}

module.exports = Base58;
