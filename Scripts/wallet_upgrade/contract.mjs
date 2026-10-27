export const BASELINE = Object.freeze({
    commit: "03b1eb841180081063c6a64e5afe58c76d7f3732",
    marketingVersion: "1.0.98",
    buildVersion: "147",
    platform: "macos",
});

export const FIXTURE_ID = "shipped-1.0.98-147";
export const ARCHIVE_DIRECTORY = "Tests/Fixtures/ShippedMain/1.0.98-147";
export const ARCHIVE_SHA256 = "abc40a4b3315a83734b6685b33afd59c0e32cfa3efd04b3d825d5ee3a3a12912";
export const FAILURE_CASES = ["wrong-password", "locked-read", "failed-add", "malformed-import"];

const originalCounts = {wallets: 3, accounts: 4, exports: 5, approvedSignatures: 4};
export const PHASES = [
    {mode: "verify-existing", state: "loaded", counts: originalCounts,
        checks: ["baseline", "storage-namespaces", "password-authentication", "wallet-identity", "account-metadata",
            "network-settings", "historical-signatures", "exports", "approved-signatures", "unchanged-storage"]},
    {mode: "mutate-existing", state: "loaded", counts: {wallets: 4, accounts: 5, exports: 0, approvedSignatures: 0},
        checks: ["baseline", "password-authentication", "wallet-created", "metadata-written", "old-sources-preserved", "mutation-record-written"]},
    {mode: "verify-reopened", state: "loaded", counts: {wallets: 4, accounts: 5, exports: 6, approvedSignatures: 5},
        checks: ["baseline", "password-authentication", "original-wallets", "created-wallet", "mutation-metadata",
            "exports", "approved-signatures", "unchanged-storage"]},
    {mode: "restore", state: "restored", counts: originalCounts,
        checks: ["baseline", "empty-store", "replacement-password", "backups-imported", "hd-paths-restored",
            "restored-identities", "exports", "approved-signatures", "restore-map-written"]},
    {mode: "verify-restored", state: "restored", counts: originalCounts,
        checks: ["baseline", "password-authentication", "restore-map", "restored-identities",
            "exports", "approved-signatures", "unchanged-storage"]},
    {mode: "failures", state: "failures", counts: {wallets: 3, accounts: 4, exports: 0, approvedSignatures: 0},
        checks: ["baseline", "wrong-password-rejected", "locked-read-rejected", "failed-add-rejected",
            "malformed-import-rejected", "failures-preserve-storage"]},
];
