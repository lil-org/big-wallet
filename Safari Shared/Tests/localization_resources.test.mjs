// ∅ 2026 lil org

import assert from "node:assert/strict";
import {readFile, readdir} from "node:fs/promises";
import test from "node:test";

const catalog = JSON.parse(await readFile(new URL(
    "../../Shared/Supporting Files/Localizable.xcstrings",
    import.meta.url
), "utf8"));
const source = "Big Wallet requests are unavailable in Private Browsing.";
const messageName = "private_browsing_unsupported";
const mappedLocales = {
    "es-419": "es_419",
    "pt-BR": "pt_BR",
    "pt-PT": "pt_PT",
    "zh-Hans": "zh_CN",
    "zh-Hant": "zh_TW",
    nb: "no",
};
const resources = new URL("../Resources/_locales/", import.meta.url);

test("WebExtension private browsing resources match every catalog locale", async () => {
    const localizations = catalog.strings[source].localizations;
    const expectedDirectories = Object.keys(localizations).map(locale => {
        return mappedLocales[locale] || locale;
    }).sort();
    const entries = await readdir(resources, {withFileTypes: true});
    const actualDirectories = entries.filter(entry => entry.isDirectory())
        .map(entry => entry.name).sort();
    assert.deepEqual(actualDirectories, expectedDirectories);

    for (const [locale, localization] of Object.entries(localizations)) {
        assert.equal(localization.stringUnit.state, "translated");
        const directory = mappedLocales[locale] || locale;
        const messages = JSON.parse(await readFile(
            new URL(`${directory}/messages.json`, resources),
            "utf8"
        ));
        const expected = {message: localization.stringUnit.value};
        if (locale === "en") {
            assert.equal(messages[messageName].message, expected.message);
        } else {
            assert.deepEqual(messages[messageName], expected);
            assert.deepEqual(messages, {[messageName]: expected});
        }
    }
});
