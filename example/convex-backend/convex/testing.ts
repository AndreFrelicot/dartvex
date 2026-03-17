// Test/demo fixtures for verifying special Convex value handling.
//
// These functions exist to validate that the Dart SDK correctly
// round-trips Int64 and bytes through the live Convex protocol.
// They are not part of the demo app's core functionality.

import { v } from "convex/values";

import { action, query } from "./_generated/server";

/**
 * Returns a fixed set of special Convex values for query-path validation.
 *
 * The Dart SDK must decode:
 *  - Int64 as BigInt
 *  - bytes as Uint8List
 */
export const specialValuesSnapshot = query({
  args: {},
  returns: v.object({
    largePositive: v.int64(),
    largeNegative: v.int64(),
    zero: v.int64(),
    sampleBytes: v.bytes(),
  }),
  handler: async () => {
    const bytes = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    return {
      largePositive: 9007199254740993n, // Number.MAX_SAFE_INTEGER + 2
      largeNegative: -9007199254740993n,
      zero: 0n,
      sampleBytes: bytes.buffer,
    };
  },
});

/**
 * Echoes Int64 and bytes values back through an action, verifying
 * the full encode → transmit → decode → re-encode → transmit → decode
 * round-trip for argument and return paths.
 */
export const echoValues = action({
  args: {
    intValue: v.int64(),
    bytesValue: v.bytes(),
  },
  returns: v.object({
    intValue: v.int64(),
    bytesValue: v.bytes(),
    intPlusOne: v.int64(),
    bytesLength: v.number(),
  }),
  handler: async (_ctx, args) => {
    return {
      intValue: args.intValue,
      bytesValue: args.bytesValue,
      intPlusOne: args.intValue + 1n,
      bytesLength: args.bytesValue.byteLength,
    };
  },
});
