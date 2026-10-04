#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <usbmuxd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <udid> <port>\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    long raw_port = strtol(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || raw_port < 1 || raw_port > 65535) {
        fprintf(stderr, "invalid port\n");
        return 2;
    }

    usbmuxd_device_info_t device;
    memset(&device, 0, sizeof(device));
    int found = usbmuxd_get_device(argv[1], &device, DEVICE_LOOKUP_USBMUX);
    if (found <= 0 || device.conn_type != CONNECTION_TYPE_USB) {
        fprintf(stderr, "target USB device unavailable\n");
        return 3;
    }

    int fd = usbmuxd_connect(device.handle, (uint16_t)raw_port);
    if (fd < 0) {
        fprintf(stderr, "connect failed: %d\n", fd);
        return 4;
    }

    struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    unsigned char buffer[256];
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count > 0) {
        fwrite(buffer, 1, (size_t)count, stdout);
    } else if (count == 0) {
        fprintf(stderr, "connected; peer closed without banner\n");
    } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        fprintf(stderr, "connected; no banner\n");
    } else {
        fprintf(stderr, "connected; read failed: %s\n", strerror(errno));
    }
    usbmuxd_disconnect(fd);
    return 0;
}
