/*
 * Compatibility stubs for prima wlan driver on kernel 4.4
 */
#include <linux/module.h>
#include <linux/string.h>

/* wcnss_get_iris_name removed from 4.4 WCNSS driver */
int wcnss_get_iris_name(char *iris_name)
{
	strlcpy(iris_name, "WCN3620", 8);
	return 0;
}
EXPORT_SYMBOL(wcnss_get_iris_name);
