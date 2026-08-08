// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/kallsyms.h>

#define PROC_NAME "dynbq"
#define H2R_FLRING_BQSIZE_NOTIF 16
#define FLRING_BQSIZE_NOTIF_DIRECT 0x2

typedef int (*runner_notify_t)(void *, int, unsigned long, unsigned long);

static runner_notify_t runner_notify;
static struct proc_dir_entry *dynbq_proc;

static ssize_t dynbq_write(struct file *file,
                           const char __user *ubuf,
                           size_t len,
                           loff_t *off)
{
    char buf[96];
    unsigned long ctx, flow, q;
    int rc;

    if (!len || len >= sizeof(buf))
        return -EINVAL;

    if (copy_from_user(buf, ubuf, len))
        return -EFAULT;

    buf[len] = '\0';

    if (sscanf(buf, "%lx %lu %lu", &ctx, &flow, &q) != 3)
        return -EINVAL;

    if (!ctx)
        return -EINVAL;

    if (flow < 2 || flow > 1023)
        return -EINVAL;

    if (q != 64 && q != 128 && q != 192)
        return -EINVAL;

    if (!runner_notify)
        return -ENODEV;

    rc = runner_notify((void *)ctx,
                       H2R_FLRING_BQSIZE_NOTIF,
                       flow,
                       q | FLRING_BQSIZE_NOTIF_DIRECT);

    return rc < 0 ? rc : len;
}

static const struct file_operations dynbq_fops = {
    .owner = THIS_MODULE,
    .write = dynbq_write,
};

static int __init dynbq_init(void)
{
    unsigned long addr = kallsyms_lookup_name("dhd_runner_notify");

    if (!addr)
        return -ENOENT;

    runner_notify = (runner_notify_t)addr;

    dynbq_proc = proc_create(PROC_NAME, 0200, NULL, &dynbq_fops);
    if (!dynbq_proc)
        return -ENOMEM;

    pr_info("dynbq: loaded notify=%px\n", runner_notify);
    return 0;
}

static void __exit dynbq_exit(void)
{
    if (dynbq_proc)
        remove_proc_entry(PROC_NAME, NULL);

    pr_info("dynbq: unloaded\n");
}

module_init(dynbq_init);
module_exit(dynbq_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Broadcom DHD Runner dynamic BQ setter");
