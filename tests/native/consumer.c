#include <sys/types.h>
#include <sys/utsname.h>
#include <agentx.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

struct callbacks {
    int connect;
    int free;
};

static void
connection(struct agentx *agent, void *cookie, int done)
{
    struct callbacks *calls = cookie;
    assert(agent != NULL);
    if (done)
        calls->free++;
    else
        calls->connect++;
}

int
main(void)
{
    struct utsname host;
    struct callbacks calls = {0};
    struct agentx *agent;
    struct agentx_session *session;
    struct agentx_context *context;

    assert(uname(&host) == 0);
    assert(strcmp(host.sysname, "OpenBSD") == 0);
    assert(strcmp(host.release, "7.9") == 0);
    agent = agentx(connection, &calls);
    assert(agent != NULL);
    assert(calls.connect == 1 && calls.free == 0);
    session = agentx_session(agent, AGENTX_OID(AGENTX_ENTERPRISES, 30155),
        "Nix native build test", 5);
    assert(session != NULL);
    context = agentx_context(session, NULL);
    assert(context != NULL);
    assert(agentx_context_object_find(context,
        AGENTX_OID(AGENTX_ENTERPRISES, 30155, 1), 0, 0) == NULL);
    agentx_free(agent);
    assert(calls.connect == 1 && calls.free == 1);
    puts("libagentx consumer passed");
    return 0;
}
