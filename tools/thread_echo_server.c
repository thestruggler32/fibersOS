/* Simple pthread-per-connection echo server.
   Compile: gcc -O2 -pthread -o bin/thread_server tools/thread_echo_server.c
*/
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define BACKLOG 128

void *conn_handler(void *arg) {
    int sock = (intptr_t)arg;
    char buf[128];
    while (1) {
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
        if (n <= 0) break;
        ssize_t w = 0;
        while (w < n) {
            ssize_t s = send(sock, buf + w, n - w, 0);
            if (s <= 0) break;
            w += s;
        }
        if (w < n) break;
    }
    close(sock);
    return NULL;
}

int main(int argc, char **argv) {
    const char *port = argc > 1 ? argv[1] : "10000";
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_PASSIVE };
    struct addrinfo *res;
    if (getaddrinfo(NULL, port, &hints, &res) != 0) {
        perror("getaddrinfo");
        return 1;
    }
    int lfd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    if (bind(lfd, res->ai_addr, res->ai_addrlen) != 0) { perror("bind"); return 1; }
    freeaddrinfo(res);
    if (listen(lfd, BACKLOG) != 0) { perror("listen"); return 1; }
    fprintf(stderr, "thread_server listening on %s\n", port);
    while (1) {
        int sock = accept(lfd, NULL, NULL);
        if (sock < 0) continue;
        pthread_t t;
        pthread_create(&t, NULL, conn_handler, (void*)(intptr_t)sock);
        pthread_detach(t);
    }
    close(lfd);
    return 0;
}
