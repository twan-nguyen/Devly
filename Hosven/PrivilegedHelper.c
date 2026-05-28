#include "PrivilegedHelper.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>

static AuthorizationRef cachedAuthRef = NULL;
static uint64_t cachedAuthCreatedAt = 0;
static pthread_mutex_t authMutex = PTHREAD_MUTEX_INITIALIZER;
static const uint64_t authorizationCacheTTLSeconds = 2 * 60 * 60;

static uint64_t currentMonotonicSeconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec;
}

static void clearCachedAuthorization(void) {
    if (cachedAuthRef != NULL) {
        AuthorizationFree(cachedAuthRef, kAuthorizationFlagDefaults);
        cachedAuthRef = NULL;
    }
    cachedAuthCreatedAt = 0;
}

static int cachedAuthorizationIsValid(void) {
    if (cachedAuthRef == NULL || cachedAuthCreatedAt == 0) {
        return 0;
    }

    uint64_t now = currentMonotonicSeconds();
    return now != 0 && now >= cachedAuthCreatedAt && (now - cachedAuthCreatedAt) < authorizationCacheTTLSeconds;
}

OSStatus acquireAuthorization(void) {
    if (cachedAuthorizationIsValid()) {
        return errAuthorizationSuccess;
    } else if (cachedAuthRef != NULL) {
        clearCachedAuthorization();
    }

    AuthorizationItem authItem = {
        .name = kAuthorizationRightExecute,
        .valueLength = 0,
        .value = NULL,
        .flags = 0
    };
    AuthorizationRights authRights = {
        .count = 1,
        .items = &authItem
    };

    AuthorizationFlags flags =
        kAuthorizationFlagInteractionAllowed |
        kAuthorizationFlagPreAuthorize |
        kAuthorizationFlagExtendRights;

    OSStatus status = AuthorizationCreate(&authRights, kAuthorizationEmptyEnvironment, flags, &cachedAuthRef);
    if (status == errAuthorizationSuccess) {
        cachedAuthCreatedAt = currentMonotonicSeconds();
    } else {
        clearCachedAuthorization();
    }
    return status;
}

OSStatus runPrivilegedShellCommand(const char *command) {
    pthread_mutex_lock(&authMutex);

    // Acquire authorization if not cached
    OSStatus status = acquireAuthorization();
    if (status != errAuthorizationSuccess) {
        pthread_mutex_unlock(&authMutex);
        return status;
    }

    char *args[] = { "-c", (char *)command, NULL };
    FILE *outputFile = NULL;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = AuthorizationExecuteWithPrivileges(cachedAuthRef, "/bin/sh", kAuthorizationFlagDefaults, args, &outputFile);
#pragma clang diagnostic pop

    if (status == errAuthorizationSuccess && outputFile != NULL) {
        char buf[4096];
        while (fgets(buf, sizeof(buf), outputFile) != NULL) {}
        fclose(outputFile);

        int childStatus;
        wait(&childStatus);
    }

    // Any privileged execution failure leaves auth state uncertain; re-prompt next time.
    if (status != errAuthorizationSuccess) {
        clearCachedAuthorization();
    }

    pthread_mutex_unlock(&authMutex);
    return status;
}

void releaseAuthorization(void) {
    pthread_mutex_lock(&authMutex);
    clearCachedAuthorization();
    pthread_mutex_unlock(&authMutex);
}
