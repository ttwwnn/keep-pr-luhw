// An inert Codex-shaped screen. No network, tools, accounts or user input.
// Tests change the adjacent .screen file to answer its made-up question.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char path[4096], screen[4096], previous[4096] = "";
    snprintf(path, sizeof(path), "%s.screen", argv[0]);
    for (;;) {
        FILE *file = fopen(path, "r");
        if (file) {
            size_t n = fread(screen, 1, sizeof(screen) - 1, file);
            screen[n] = 0;
            fclose(file);
            if (strcmp(screen, previous)) {
                printf("\033]0;Codex question\007\033[2J\033[H%s", screen);
                fflush(stdout);
                strcpy(previous, screen);
            }
        }
        usleep(100000);
    }
}
