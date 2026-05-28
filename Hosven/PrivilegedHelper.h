#ifndef PrivilegedHelper_h
#define PrivilegedHelper_h

#include <Security/Security.h>

/// Acquire admin authorization (shows password dialog on first call, cached for up to 2 hours).
/// Returns errAuthorizationSuccess on success.
OSStatus acquireAuthorization(void);

/// Run a shell command with cached admin privileges.
/// Call acquireAuthorization() first. Returns errAuthorizationSuccess on success.
OSStatus runPrivilegedShellCommand(const char *command);

/// Free the cached authorization (call on app termination).
void releaseAuthorization(void);

#endif
