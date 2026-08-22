/*
 * env-module.c - a shared object that says it was loaded
 *
 * SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
 * SPDX-License-Identifier: ISC
 *
 * env.sh builds one copy of this per knob it points at the file, each with its
 * own NT_MOD_TAG, and then asks whether the tag turned up. The constructor is
 * the whole point: it runs at load time, before any entry point the loader
 * looks for, so a knob that merely opens the file has already executed code
 * whether or not the toolkit went on to accept it as a module.
 *
 * The mark directory arrives in the environment rather than at compile time
 * because the loader under test is a confined process: the only directory it
 * may write to is its own app dir, and that path is not known until netinstall
 * has resolved the spec.
 */

#include <stdio.h>
#include <stdlib.h>

#ifndef NT_MOD_TAG
#define NT_MOD_TAG "untagged"
#endif

static void nt_mod_mark(void) __attribute__((constructor));

static void nt_mod_mark(void)
{
    const char *dir = getenv("NEUTRINO_TEST_MODULE_MARKDIR");
    char path[4096];
    FILE *f;

    if (!dir) {
        return;
    }
    if (snprintf(path, sizeof(path), "%s/%s", dir, NT_MOD_TAG) >= (int)sizeof(path)) {
        return;
    }
    f = fopen(path, "w");
    if (!f) {
        return;
    }
    fputs(NT_MOD_TAG "\n", f);
    fclose(f);
}

/*
 * The entry points the two toolkits look for after opening the file. Neither is
 * needed for the constructor to run, and providing them is not an attempt to
 * make the probe easier: without them the load is aborted with a log line, and
 * the question would become "does a broken module get rejected" instead of
 * "does this knob load a file this process was not built with".
 */
void gtk_module_init(int *argc, char ***argv);
void gtk_module_init(int *argc, char ***argv)
{
    (void)argc;
    (void)argv;
}

void WKBundleInitialize(void *bundle, void *initializationUserData);
void WKBundleInitialize(void *bundle, void *initializationUserData)
{
    (void)bundle;
    (void)initializationUserData;
}
