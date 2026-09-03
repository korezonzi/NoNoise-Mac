#ifndef NN_EXCEPTION_GUARD_H
#define NN_EXCEPTION_GUARD_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and catches any Objective-C `NSException` it raises (Swift's `do`/`catch` cannot —
/// an uncaught NSException aborts the whole process). Returns `nil` on success, or the exception's
/// "name: reason" description on catch.
///
/// Motivation (field crash 2026-09-03): AVAudioEngine graph calls (`installTap`, `connect`,
/// `start`) raise NSExceptions for conditions that cannot all be pre-validated (observed:
/// `AUGraphNodeBaseV3::CreateRecordingTap` aborting the app from `VoiceIOEngine.buildAndStart()`
/// despite a passing bus-format pre-check). A beta capture backend must degrade to the AVCapture
/// fallback, never take down the app — every re-render consumer (NoNoise Speaker routing) goes
/// silent when the process dies.
///
/// Swift-side contract: the block MUST NOT throw Swift errors across this boundary (wrap them in
/// a captured local instead) and must not be used on realtime audio threads.
NSString * _Nullable NNCatchNSException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

#endif /* NN_EXCEPTION_GUARD_H */
