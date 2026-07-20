#!/usr/bin/env node

import { resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  createProtectedProductionSnapshot,
  loadProductionWranglerContract,
  productionWranglerArguments,
  SafeProductionWranglerError,
  spawnPinnedProductionWrangler,
} from "./production-contract.mjs";

const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const VERSION_SPECIFICATION =
  /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})@(0|[1-9][0-9]?|100)$/u;
const PRINTABLE_MESSAGE =
  /^(?=.{1,512}$)(?=.*[\u0021-\u007e])[\u0020-\u007e]+$/u;

export class SafeRolloutError extends Error {
  constructor(message) {
    super(message);
    this.name = "SafeRolloutError";
  }
}

function fail(message) {
  return new SafeRolloutError(message);
}

function usage() {
  return [
    "Usage: npm run rollout -- <command>",
    "",
    "Commands:",
    "  deployments-list",
    "  versions-list",
    "  deploy UUID@100 [UUID@0] --message \"Printable message\"",
  ].join("\n");
}

function parseVersionSpecifications(values) {
  if (values.length === 0) {
    throw fail("deploy requires at least one version specification");
  }
  if (values.length > 2) {
    throw fail("deploy supports at most two version specifications");
  }
  const versions = [];
  const seen = new Set();
  let totalPercentage = 0;
  for (const value of values) {
    const match = VERSION_SPECIFICATION.exec(value);
    if (match === null || !CANONICAL_UUID.test(match[1])) {
      throw fail("version specifications must use canonical UUID@percentage");
    }
    const version = match[1];
    if (seen.has(version)) {
      throw fail("version specifications must be unique");
    }
    seen.add(version);
    const percentage = Number(match[2]);
    totalPercentage += percentage;
    versions.push(`${version}@${percentage}`);
  }
  if (totalPercentage !== 100) {
    throw fail("version percentages must total 100");
  }
  return versions;
}

export function parseRolloutArguments(arguments_) {
  if (arguments_.length === 1 && arguments_[0] === "--help") {
    return { command: "help" };
  }
  if (
    arguments_.length === 1 &&
    (arguments_[0] === "deployments-list" ||
      arguments_[0] === "versions-list")
  ) {
    return { command: arguments_[0] };
  }
  if (arguments_[0] !== "deploy") {
    throw fail("unknown rollout command");
  }

  const messageIndexes = arguments_
    .map((value, index) => value === "--message" ? index : -1)
    .filter((index) => index !== -1);
  if (
    messageIndexes.length !== 1 ||
    messageIndexes[0] !== arguments_.length - 2
  ) {
    throw fail("deploy requires one final --message option");
  }
  const messageIndex = messageIndexes[0];
  const message = arguments_[messageIndex + 1];
  if (message === undefined || !PRINTABLE_MESSAGE.test(message)) {
    throw fail("deployment message must be printable");
  }
  const versionValues = arguments_.slice(1, messageIndex);
  if (versionValues.some((value) => value.startsWith("-"))) {
    throw fail("arbitrary rollout flags are not supported");
  }
  return {
    command: "deploy",
    message,
    versions: parseVersionSpecifications(versionValues),
  };
}

export async function executeRollout(
  options,
  {
    contractLoader = loadProductionWranglerContract,
    snapshotFactory = createProtectedProductionSnapshot,
    runner = spawnPinnedProductionWrangler,
  } = {},
) {
  if (options.command === "help") {
    return;
  }
  const contract = await contractLoader();
  const snapshot = await snapshotFactory(contract);
  try {
    let commandArguments;
    let assumeYes = false;
    if (options.command === "deployments-list") {
      commandArguments = ["deployments", "list"];
    } else if (options.command === "versions-list") {
      commandArguments = ["versions", "list"];
    } else {
      commandArguments = [
        "versions",
        "deploy",
        ...options.versions,
        `--message=${options.message}`,
      ];
      assumeYes = true;
    }
    const arguments_ = productionWranglerArguments({
      commandArguments,
      configPath: snapshot.configPath,
      workerName: contract.workerName,
      emptyEnvironmentPath: snapshot.emptyEnvironmentPath,
      assumeYes,
    });
    await snapshot.verify();
    await runner({
      arguments_,
      workingDirectory: snapshot.workerDirectory,
    });
  } finally {
    await snapshot.cleanup();
  }
}

export async function rolloutMain(
  arguments_,
  {
    stdout = (message) => process.stdout.write(message),
    stderr = (message) => process.stderr.write(message),
    executor = executeRollout,
  } = {},
) {
  try {
    const options = parseRolloutArguments(arguments_);
    if (options.command === "help") {
      stdout(`${usage()}\n`);
      return 0;
    }
    await executor(options);
    return 0;
  } catch (error) {
    const message =
      error instanceof SafeRolloutError ||
      error instanceof SafeProductionWranglerError
        ? error.message
        : "production rollout failed";
    stderr(`${message}\n`);
    return 1;
  }
}

const isMain =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  process.exitCode = await rolloutMain(process.argv.slice(2));
}
