#import "include/nn_exception_guard.h"

NSString * _Nullable NNCatchNSException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *name = exception.name ?: @"NSException";
        NSString *reason = exception.reason ?: @"(no reason)";
        return [NSString stringWithFormat:@"%@: %@", name, reason];
    }
}
