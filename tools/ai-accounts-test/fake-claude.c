// A stand-in for Claude Code in a scratch daemon's tab, for the tests of a
// tab's AI menu (tools/account-menu-test.sh).
//
// What the app reads to know a tab runs Claude Code is the name of the
// process holding its terminal, and the name is the executable's: this is
// built as a file called `claude`. It draws what Claude Code draws when its
// turn is over — the last status line, the prompt box, the footer under it —
// and then waits, for as long as the tab lasts, doing nothing at all. It
// reads no keys and sends nothing anywhere.
#include <stdio.h>
#include <unistd.h>

int main(void) {
    const char *rule = "────────────────────────────────────────────────────────";
    printf("\033]0;✳ Claude Code\007\033[2J\033[H");
    printf("⏺ Done.\n\n✻ Baked for 2s\n\n%s\n❯ \n%s\n  ⏵⏵ bypass permissions on\n", rule, rule);
    fflush(stdout);
    for (;;) pause();
}
