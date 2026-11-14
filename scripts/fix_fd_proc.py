#!/usr/bin/env python3
# OPPO 的 fs/proc/fd.c 与 SUSFS 官方补丁冲突（OPPO 精简了 seq_show 的 ino 字段）。
# 这里按 SUSFS 官方语义把 sus_mount 的假 mnt_id 逻辑加回去，但保留 OPPO 原有的输出格式。
import sys

OLD = """\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t   (long long)file->f_pos, f_flags,
\t\t   real_mount(file->f_path.mnt)->mnt_id);
"""

NEW = """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tmnt = real_mount(file->f_path.mnt);
\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) &&
\t\t\tmnt->mnt_id >= DEFAULT_SUS_MNT_ID) {
\t\tstruct path path;
\t\tchar *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
\t\tchar *dpath;

\t\tfor (; mnt->mnt_id >= DEFAULT_SUS_MNT_ID; mnt = mnt->mnt_parent) { }

\t\tif (!pathname)
\t\t\tgoto out_seq_printf;
\t\tdpath = d_path(&file->f_path, pathname, PAGE_SIZE);
\t\tif (!dpath)
\t\t\tgoto out_free_pathname;
\t\tif (kern_path(dpath, 0, &path))
\t\t\tgoto out_free_pathname;
\t\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t\t\t(long long)file->f_pos, f_flags, mnt->mnt_id);
\t\tpath_put(&path);
\t\tkfree(pathname);
\t\tgoto bypass_orig_flow;
out_free_pathname:
\t\tkfree(pathname);
\t}
out_seq_printf:
#endif
\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t   (long long)file->f_pos, f_flags,
\t\t   real_mount(file->f_path.mnt)->mnt_id);
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
bypass_orig_flow:
#endif
"""


def main(path: str) -> int:
    s = open(path).read()
    if "bypass_orig_flow" in s:
        print("[=] 已包含 SUSFS 逻辑，跳过")
        return 0
    if OLD not in s:
        print("[-] 找不到目标 seq_printf 块，需要人工处理")
        return 1
    if "struct mount *mnt = NULL;" not in s:
        s = s.replace("\tstruct task_struct *task;",
                      "\tstruct task_struct *task;\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tstruct mount *mnt = NULL;\n#endif", 1)
    s = s.replace(OLD, NEW, 1)
    open(path, "w").write(s)
    print("[+] fs/proc/fd.c 已修正")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "fs/proc/fd.c"))
