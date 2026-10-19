/* nix-openbsd helper using OpenBSD cron's parser and reload protocol. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <bitstring.h>
#include <err.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "cron.h"

static const char *filename;
static int errors;

static void
parse_error(const char *message)
{

	fprintf(stderr, "%s:%d: %s\n", filename, LineNumber - 1, message);
	errors++;
}

static int
check(const char *path)
{
	FILE *file;
	char envstr[MAX_ENVSTR], **envp;
	entry *e;
	int status;

	filename = path;
	if ((file = fopen(path, "r")) == NULL)
		err(1, "%s", path);
	if (pledge("stdio rpath getpw", NULL) == -1)
		err(1, "pledge");
	if ((envp = env_init()) == NULL)
		err(1, "env_init");
	LineNumber = 1;
	while (!errors) {
		status = load_env(envstr, file);
		if (status == -1) {
			if (envstr[0] != '\0') {
				LineNumber++;
				parse_error("premature EOF");
			}
			break;
		}
		if (status == FALSE) {
			e = load_entry(file, parse_error, NULL, envp);
			if (e != NULL)
				free_entry(e);
		}
	}
	if (ferror(file))
		err(1, "%s", path);
	env_free(envp);
	fclose(file);
	return errors != 0;
}

static int
reload(void)
{
	struct sockaddr_un address = { .sun_family = AF_UNIX };
	unsigned char cookie = RELOAD_CRON;
	int fd;

	if (pledge("stdio unix", NULL) == -1)
		err(1, "pledge");
	if (strlcpy(address.sun_path, _PATH_CRON_SOCK,
	    sizeof(address.sun_path)) >= sizeof(address.sun_path))
		errx(1, "cron socket path too long");
	if ((fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1)
		err(1, "socket");
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == -1)
		err(1, "connect: %s", address.sun_path);
	/* Like cron's client.c: the daemon defaults to reloading if it closes
	 * the accepted connection before reading our cookie. */
	(void)send(fd, &cookie, sizeof(cookie), MSG_NOSIGNAL);
	close(fd);
	return 0;
}

int
main(int argc, char **argv)
{

	if (argc == 3 && strcmp(argv[1], "check") == 0)
		return check(argv[2]);
	if (argc == 2 && strcmp(argv[1], "reload") == 0)
		return reload();
	fprintf(stderr, "usage: cronctl {check FILE|reload}\n");
	return 1;
}
