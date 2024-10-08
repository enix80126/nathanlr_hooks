#include <fishhook.h>
#include <xpc/xpc.h>
#include <spawn.h>
#include <dirent.h>
#include <mount_bindfs.h>
#include <sys/mount.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include "sandbox.h"
#include <sys/clonefile.h>
#import <mach-o/dyld.h>

#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
#define POSIX_SPAWNATTR_OFF_MEMLIMIT_ACTIVE 0x48
#define POSIX_SPAWNATTR_OFF_MEMLIMIT_INACTIVE 0x4C
#define JETSAM_MULTIPLIER 3

int posix_spawnattr_set_launch_type_np(posix_spawnattr_t *attr, uint8_t launch_type);

int (*orig_csops)(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize);
int (*orig_csops_audittoken)(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize, audit_token_t * token);
int (*orig_posix_spawn)(pid_t * __restrict pid, const char * __restrict path,
                        const posix_spawn_file_actions_t *file_actions,
                        const posix_spawnattr_t * __restrict attrp,
                        char *const argv[ __restrict], char *const envp[ __restrict]);
int (*orig_posix_spawnp)(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict file_actions, const posix_spawnattr_t *restrict attrp, char *const argv[restrict], char *const envp[restrict]);
bool (*xpc_dictionary_get_bool_orig)(xpc_object_t dictionary, const char *key);
xpc_object_t (*xpc_dictionary_get_value_orig)(xpc_object_t xdict, const char *key);
int (*memorystatus_control_orig)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

NSString* safe_getExecutablePath()
{
    char executablePathC[PATH_MAX];
    uint32_t executablePathCSize = sizeof(executablePathC);
    _NSGetExecutablePath(&executablePathC[0], &executablePathCSize);
    return [NSString stringWithUTF8String:executablePathC];
}

NSString* getProcessName()
{
    return safe_getExecutablePath().lastPathComponent;
}

char *JB_SandboxExtensions = NULL;

int hooked_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int result = orig_csops(pid, ops, useraddr, usersize);
    if (result != 0) return result;
    if (ops == 0) {
        *((uint32_t *)useraddr) |= 0x4000000;
    }
    return result;
}

int hooked_csops_audittoken(pid_t pid, unsigned int ops, void * useraddr, size_t usersize, audit_token_t * token) {
    int result = orig_csops_audittoken(pid, ops, useraddr, usersize, token);
    if (result != 0) return result;
    if (ops == 0) {
        *((uint32_t *)useraddr) |= 0x4000000;
    }
    return result;
}

//void change_launchtype(posix_spawnattr_t *attrp, const char *restrict path) {
//    if (strncmp(path, "/var/jb", 7) == 0) {
//        if (attrp != 0) {
//            posix_spawnattr_set_launch_type_np(attrp, 0);
//        }
//    }
//}

int envbuf_find(const char *envp[], const char *name)
{
    if (envp) {
        unsigned long nameLen = strlen(name);
        int k = 0;
        const char *env = envp[k++];
        while (env != NULL) {
            unsigned long envLen = strlen(env);
            if (envLen > nameLen) {
                if (!strncmp(env, name, nameLen)) {
                    if (env[nameLen] == '=') {
                        return k-1;
                    }
                }
            }
            env = envp[k++];
        }
    }
    return -1;
}

int envbuf_len(const char *envp[])
{
    if (envp == NULL) return 1;

    int k = 0;
    const char *env = envp[k++];
    while (env != NULL) {
        env = envp[k++];
    }
    return k;
}

void envbuf_setenv(char **envpp[], const char *name, const char *value)
{
    if (envpp) {
        char **envp = *envpp;
        if (!envp) {
            // treat NULL as [NULL]
            envp = malloc(sizeof(const char *));
            envp[0] = NULL;
        }

        char *envToSet = malloc(strlen(name)+strlen(value)+2);
        strcpy(envToSet, name);
        strcat(envToSet, "=");
        strcat(envToSet, value);

        int existingEnvIndex = envbuf_find((const char **)envp, name);
        if (existingEnvIndex >= 0) {
            // if already exists: deallocate old variable, then replace pointer
            free(envp[existingEnvIndex]);
            envp[existingEnvIndex] = envToSet;
        }
        else {
            // if doesn't exist yet: increase env buffer size, place at end
            int prevLen = envbuf_len((const char **)envp);
            *envpp = realloc(envp, (prevLen+1)*sizeof(const char *));
            envp = *envpp;
            envp[prevLen-1] = envToSet;
            envp[prevLen] = NULL;
        }
    }
}

char **envbuf_mutcopy(const char *envp[])
{
    if (envp == NULL) return NULL;

    int len = envbuf_len(envp);
    char **envcopy = malloc(len * sizeof(char *));

    for (int i = 0; i < len-1; i++) {
        envcopy[i] = strdup(envp[i]);
    }
    envcopy[len-1] = NULL;

    return envcopy;
}
void envbuf_free(char *envp[])
{
    if (envp == NULL) return;

    int len = envbuf_len((const char**)envp);
    for (int i = 0; i < len-1; i++) {
        free(envp[i]);
    }
    free(envp);
}

void increaseJetsamLimits(posix_spawnattr_t *attrp) {
    uint8_t *attrStruct = *attrp;
        int memlimit_active = *(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_ACTIVE);
        if (memlimit_active != -1) {
            *(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_ACTIVE) = memlimit_active * JETSAM_MULTIPLIER;
        }
        int memlimit_inactive = *(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_INACTIVE);
        if (memlimit_inactive != -1) {
            *(int*)(attrStruct + POSIX_SPAWNATTR_OFF_MEMLIMIT_INACTIVE) = memlimit_inactive * JETSAM_MULTIPLIER;
        }
}

NSString *generateSystemWideSandboxExtensions(void)
{
    NSMutableString *extensionString = [NSMutableString new];
    const char *sandboxPath = "/var/jb";

    // Make /var/jb readable
    [extensionString appendString:[NSString stringWithUTF8String:sandbox_extension_issue_file("com.apple.app-sandbox.read", sandboxPath, 0)]];
    [extensionString appendString:@"|"];

    // Make binaries in /var/jb executable
    [extensionString appendString:[NSString stringWithUTF8String:sandbox_extension_issue_file("com.apple.sandbox.executable", sandboxPath, 0)]];
    [extensionString appendString:@"|"];

    // Ensure the whole system has access to com.opa334.jailbreakd.systemwide
    [extensionString appendString:[NSString stringWithUTF8String:sandbox_extension_issue_mach("com.apple.app-sandbox.mach", "com.hrtowii.jitterd.systemwide", 0)]];
    [extensionString appendString:@"|"];
    [extensionString appendString:[NSString stringWithUTF8String:sandbox_extension_issue_mach("com.apple.security.exception.mach-lookup.global-name", "com.hrtowii.jitterd.systemwide", 0)]];

    return extensionString;
}

int hooked_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, posix_spawnattr_t *attrp, char *argv[], char *const envp[]) {
    
    if (strncmp(path, "/var/containers/Bundle/Application/", 35) == 0) {

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", path, "_NATHANLR");

        if (access(newPath, F_OK) == 0) {
            char bakPath[PATH_MAX];
            snprintf(bakPath, sizeof(bakPath), "%s%s", path, ".bak");
            rename(path, bakPath);
            clonefile(newPath, path, 0);
            increaseJetsamLimits(attrp);
            int ret = orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
            remove(path);
            rename(bakPath, path);
            return ret;
        }
    } else if (strncmp(path, "/Applications/", 14) == 0) {
        const char *appSubPath = path + 14;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/Applications/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            int ret = orig_posix_spawn(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strstr(path, "/jb/Applications/") != NULL) {
        char **envc = envbuf_mutcopy((const char **)envp);
        envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
        increaseJetsamLimits(attrp);
        int ret = orig_posix_spawn(pid, path, file_actions, attrp, argv, envc);
        envbuf_free(envc);
        return ret;
    } else if (strcmp(path, "/sbin/launchd") == 0) {
        path = "/var/jb/System/Library/SysBins/launchd";
        argv[0] = (char *)path;
        posix_spawnattr_set_launch_type_np(attrp, 0);
    }
    
    return orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
}


int hooked_posix_spawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, posix_spawnattr_t *attrp, char *argv[], char *const envp[]) {
    
    if (strncmp(path, "/Applications/", 14) == 0) {
        const char *appSubPath = path + 14;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/Applications/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/System/Library/CoreServices/", 29) == 0) {
        const char *appSubPath = path + 29;
        
        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/CoreServices/", appSubPath);
        
        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
        }
    } else if (strcmp(path, "/usr/libexec/xpcproxy") == 0) {
        path = "/var/jb/System/Library/SysBins/xpcproxy";
        argv[0] = (char *)path;
        char **envc = envbuf_mutcopy((const char **)envp);
        envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/launchdhook.dylib");
        posix_spawnattr_set_launch_type_np(attrp, 0);
        int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
        envbuf_free(envc);
        return ret;
    }

    return orig_posix_spawnp(pid, path, file_actions, attrp, argv, envp);
}

int hooked_posix_spawn_xpcproxy(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, posix_spawnattr_t *attrp, char *argv[], char *const envp[]) {

    if (strncmp(path, "/System/Library/PrivateFrameworks/", 34) == 0) {
        const char *appSubPath = path + 34;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawn(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/usr/libexec/", 13) == 0) {
        const char *appSubPath = path + 13;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawn(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    }
    
    return orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

int hooked_posix_spawnp_xpcproxy(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, posix_spawnattr_t *attrp, char *argv[], char *const envp[]) {
    
    if (strncmp(path, "/System/Library/PrivateFrameworks/", 34) == 0) {
        const char *appSubPath = path + 34;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/System/Library/Frameworks/", 27) == 0) {
        const char *appSubPath = path + 27;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/usr/libexec/", 13) == 0) {
        const char *appSubPath = path + 13;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/usr/sbin/", 10) == 0) {
        const char *appSubPath = path + 10;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            int ret = 0;
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            if (strncmp(path, "/System/Library/VideoCodecs/SysBins/cfprefsd", 44) == 0) {
                ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envp);
            } else {
                ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            }
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/usr/bin/", 9) == 0) {
        const char *appSubPath = path + 9;

        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/SysBins/", appSubPath);

        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    } else if (strncmp(path, "/System/Library/CoreServices/", 29) == 0) {
        const char *appSubPath = path + 29;
        
        char newPath[PATH_MAX];
        snprintf(newPath, sizeof(newPath), "%s%s", "/System/Library/VideoCodecs/CoreServices/", appSubPath);
        
        if (access(newPath, F_OK) == 0) {
            path = newPath;
            argv[0] = (char *)path;
            char **envc = envbuf_mutcopy((const char **)envp);
            envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", "/System/Library/VideoCodecs/lib/hooks/generalhook.dylib");
            increaseJetsamLimits(attrp);
            posix_spawnattr_set_launch_type_np(attrp, 0);
            int ret = orig_posix_spawnp(pid, path, file_actions, attrp, argv, envc);
            envbuf_free(envc);
            return ret;
        }
    }
    
    return orig_posix_spawnp(pid, path, file_actions, attrp, argv, envp);
}

bool hook_xpc_dictionary_get_bool(xpc_object_t dictionary, const char *key) {
    if (!strcmp(key, "LogPerformanceStatistics")) return true;
    else return xpc_dictionary_get_bool_orig(dictionary, key);
}

xpc_object_t hook_xpc_dictionary_get_value(xpc_object_t dict, const char *key) {
    xpc_object_t retval = xpc_dictionary_get_value_orig(dict, key);
    
    if (!strcmp(key, "Paths")) {
        if (xpc_get_type(retval) == XPC_TYPE_ARRAY) {
            xpc_array_set_string(retval, XPC_ARRAY_APPEND, "/var/jb/basebins/LaunchDaemons");
            xpc_array_set_string(retval, XPC_ARRAY_APPEND, "/var/jb/Library/LaunchDaemons");
        }
    }

    return retval;
}

int memorystatus_control_hook(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize)
{
    if (command == MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT) {
        return 0;
    }
    return memorystatus_control_orig(command, pid, flags, buffer, buffersize);
}

void writeSandboxExtensionsToPlist() {
    NSString *filePath = @"/var/jb/System/Library/NLR_SANDBOX_EXTENSIONS.plist";
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    [fileManager removeItemAtPath:filePath error:nil];
    
    NSString *sandboxExtensions = generateSystemWideSandboxExtensions();
    
    NSDictionary *plistDict = @{@"NLR_SANDBOX_EXTENSIONS": sandboxExtensions};
    
    BOOL success = [plistDict writeToFile:filePath atomically:YES];
}

struct rebinding rebindings[7] = {
    {"csops", hooked_csops, (void *)&orig_csops},
    {"csops_audittoken", hooked_csops_audittoken, (void *)&orig_csops_audittoken},
    {"posix_spawn", hooked_posix_spawn, (void *)&orig_posix_spawn},
    {"posix_spawnp", hooked_posix_spawnp, (void *)&orig_posix_spawnp},
    {"xpc_dictionary_get_value", hook_xpc_dictionary_get_value, (void *)&xpc_dictionary_get_value_orig},
    {"xpc_dictionary_get_bool", hook_xpc_dictionary_get_bool, (void *)&xpc_dictionary_get_bool_orig},
    {"memorystatus_control", memorystatus_control_hook, (void *)&memorystatus_control_orig},
};

struct rebinding rebindings_xpcproxy[2] = {
    {"posix_spawn", hooked_posix_spawn_xpcproxy, (void *)&orig_posix_spawn},
    {"posix_spawnp", hooked_posix_spawnp_xpcproxy, (void *)&orig_posix_spawnp},
};

__attribute__((constructor)) static void init(int argc, char **argv) {
    NSString *processName = getProcessName();
    if ([processName isEqualToString:@"xpcproxy"]) {
        unsetenv("DYLD_INSERT_LIBRARIES");
        rebind_symbols(rebindings_xpcproxy, 2);
    } else if ([processName isEqualToString:@"launchd"]) {
        if (access("/System/Library/VideoCodecs/CoreServices", F_OK) != -1) {
        } else {
            bindfs("/private/var/jb/System/Library/", "/System/Library/VideoCodecs");
        }
        
        if (access("/System/Library/VideoCodecs/lib/libiosexec.1.dylib", F_OK) != -1) {
            unmount("/System/Library/VideoCodecs/lib/", MNT_FORCE);
            unmount("/System/Library/VideoCodecs/", MNT_FORCE);
            bindfs("/private/var/jb/System/Library/", "/System/Library/VideoCodecs");
            bindfs("/private/var/jb/usr/lib/", "/System/Library/VideoCodecs/lib");
        } else {
            bindfs("/private/var/jb/usr/lib/", "/System/Library/VideoCodecs/lib");
        }
        bindfs("/private/var/jb/System/Library/Fonts", "/System/Library/Fonts");
        writeSandboxExtensionsToPlist();
        rebind_symbols(rebindings, 7);
    }
}
