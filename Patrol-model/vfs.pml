#define MAXDENTRY 1024
#define MAXSYMSTACK 1024
#define MAXPATHLEGTH 6
#define MAXSUBDIR 7     // 2^FILENAMEBIT - 1 ( minus 1 means pass the root "0" )
// #define FILENAMEBIT 3

#define MAXPATHNUM 1024

// define error type
#define EPERM          -1          // Operation not permitted
#define ENOMEM         -2          // Not enough space/cannot allocate memory
#define ENAMETOOLONG   -3          // Filename too long
#define EEXIST         -4          // File exists
#define ENOENT         -5          // No such file or directory 

// define open flags
#define O_CREAT        1000        // If pathname does not exist, create it as a regular file.
#define FMODE_EXEC     2000        // open and execution

typedef d_name {
    short string;
}

typedef patharray {
    d_name pathname[MAXPATHLEGTH];
    short length = -1;
}

typedef mountns {
    short id;
}

typedef dentry {
    short d_parent;  
    short d_subdirs[MAXSUBDIR];
    short sub_index = -1;

    d_name name;

    bool d_symlink;
    patharray d_symname;  // symlink flag
    
    mountns d_mntns;   // namespace tag

    bool invalid = false;   // set true after being deleted 
}

typedef dcache {
    dentry dentries[MAXDENTRY];
    short index = -1;
} 

typedef nameidata {
    short root;
    short dentry_t;
    short dent_stack[MAXSYMSTACK];
    short stack_index = -1;
    bool done = false;
}

// process struct
typedef task_struct {
    short root;
    short cwd;
    
    mountns mnt_ns;
}

typedef destination {
    patharray destpath;
    short destscope = -1;
}

dcache dtree;
mountns host_ns;        // host mount ns
mountns container_ns;   // container mnt ns
task_struct host_t;
destination host_path;
task_struct container_t;
destination cont_path;

patharray allPaths[MAXPATHNUM];
short path_num;

short stopsign = 0;

// basic function
inline compare_pathname(src, dst, retv)
{
    if 
        :: src.string == dst.string ->
            retv = true;
        :: else ->
            retv = false;
    fi;
}

inline equal_pathstring(src, dst)
{
    short index = 0;
    do  
        :: index <= src.length ->
            dst.pathname[index].string = src.pathname[index].string;
            index++;
        :: else -> break;
    od;
    dst.length = src.length; 
}

inline transformHost2Container(controot, hostpath, contpath, error)
{
    short root_idx = 0;
    short cont_idx = 0;
    do
        :: root_idx <= controot.length ->
            if
                :: controot.pathname[root_idx].string != hostpath.pathname[root_idx].string ->
                    error = 1;
                    goto end;
                :: else ->
                    root_idx++;
            fi;
        :: else -> break;
    od;

    contpath.pathname[cont_idx].string = 0;
    contpath.length = cont_idx;
    do
        :: root_idx <= hostpath.length ->
            cont_idx++;
            contpath.pathname[cont_idx].string = hostpath.pathname[root_idx].string;
            contpath.length = cont_idx;
            root_idx++;
        :: else -> break;
    od;
end:
}

inline printPath(pathstring)
{
    short j = 0;
    printf("[path]: ");
    do
        :: j <= pathstring.length ->
            printf("/%d", pathstring.pathname[j].string);
            j++;
        :: else ->
            printf("\n"); 
            break;
    od;
}

//===================================================
//                vfs: path lookup
//===================================================
inline d_alloc (parent, name_s, symarray, mntns_id, returnval, error) 
{
    returnval = -1;

    // total limitation
    if 
        :: dtree.index < MAXDENTRY - 1 -> 
            dtree.index++;
        :: else -> 
            error = ENOMEM;
            goto end;
    fi

    // alloc root
    if
        :: parent == -1 ->
            name_s = 0;
            symarray.length = -1;
            goto root;
        :: else
    fi;

    // name confilct
    short idx = 0;
    do
        :: idx <= dtree.dentries[parent].sub_index ->
            short child = dtree.dentries[parent].d_subdirs[idx];
            idx++;
            if 
                :: dtree.dentries[child].name.string == name_s ->
                    error = EEXIST;
                    goto end;
                :: else
            fi;
        :: else -> break;
    od;

    // subdir limitation
    if 
        :: dtree.dentries[parent].sub_index < MAXSUBDIR - 1 ->
            dtree.dentries[parent].sub_index++;
            dtree.dentries[parent].d_subdirs[dtree.dentries[parent].sub_index] = dtree.index;
        :: else ->
            error = ENOMEM;
            goto end;
    fi;

root:
    // init dentry
    dtree.dentries[dtree.index].d_parent = parent;
    dtree.dentries[dtree.index].name.string = name_s;
    dtree.dentries[dtree.index].d_mntns.id = mntns_id;
    returnval = dtree.index;

    // init symlink
    if 
        :: symarray.length >= 0 ->
            dtree.dentries[dtree.index].d_symlink = true;
            dtree.dentries[dtree.index].d_symname.length = symarray.length;

            short sym_idx = 0;
            do
                :: sym_idx <= symarray.length ->
                    dtree.dentries[dtree.index].d_symname.pathname[sym_idx].string = symarray.pathname[sym_idx].string;
                    sym_idx++;
                :: else -> break;
            od;
        :: else ->
            dtree.dentries[dtree.index].d_symlink = false;
    fi;

    // init subdir
    short sidx;
    for (sidx: 0 .. MAXSUBDIR - 1){
        dtree.dentries[dtree.index].d_subdirs[sidx] = -1;
    }

end:
}

inline walk_component(nd, tname, error)
{
    // search d_sundir
    short sub_idx = 0;
    bool match = false;
    short subdir_num;
    short sub_dent_idx;
    d_name subdir_name;
    error = ENOENT;

    subdir_num = dtree.dentries[nd.dentry_t].sub_index;
    do
        :: sub_idx <= subdir_num ->
            sub_dent_idx = dtree.dentries[nd.dentry_t].d_subdirs[sub_idx];
            subdir_name.string = dtree.dentries[sub_dent_idx].name.string;
            compare_pathname(tname, subdir_name, match);
            if
                :: match == true -> 
                    error = 0;
                    nd.dentry_t = sub_dent_idx;          // current dentry
                    if 
                        // save all dentries of each path component
                        :: nd.stack_index < MAXSYMSTACK - 1 ->
                            nd.stack_index++;
                            nd.dent_stack[nd.stack_index] = sub_dent_idx;
                        :: else
                    fi;
                    break;
                :: else ->
                    sub_idx++;
            fi;
        :: else -> break;
    od;
}

inline trailing_symlink(nd, pathstring, position) 
{
    short slen;
    short sym_idx = 0;
    short stack_idx;
    patharray sym_name;

    // symlink dst first
    slen = dtree.dentries[nd.dentry_t].d_symname.length;
    do 
        :: sym_idx <= slen ->
            sym_name.pathname[sym_idx].string = dtree.dentries[nd.dentry_t].d_symname.pathname[sym_idx].string;
            sym_name.length = sym_idx;
            sym_idx++;
        :: else -> break;
    od;

    position++;
    do 
        :: position <= pathstring.length ->
            sym_name.pathname[sym_idx].string = pathstring.pathname[position].string;
            sym_name.length = sym_idx;
            sym_idx++;
            position++;
        :: else ->
            // equal_pathstring(sym_name, pathstring);
            break;
    od;

    equal_pathstring(sym_name, pathstring);

    // set the startpoint of the resolution
    if 
        :: pathstring.pathname[0].string == 0 ->
            nd.dentry_t = nd.root;
        :: else ->
            stack_idx = nd.stack_index - 1;
            nd.stack_index = stack_idx;         // back one step
            if 
                :: stack_idx == -1 ->
                    nd.dentry_t = nd.root;       
                :: else ->
                    nd.dentry_t = nd.dent_stack[stack_idx];
            fi;
    fi;
}

inline link_path_walk(nd, pathstring, error)
{
    short comp_idx = 0;
    short walk_err = 0;

    do
        // keep the last one to last_component()
        :: comp_idx <= pathstring.length - 1 ->
            // passing the walk_component for root
            if 
                :: comp_idx == 0 && pathstring.pathname[comp_idx].string == 0 ->
                    comp_idx++;
                    if
                        :: comp_idx > pathstring.length - 1 ->
                            goto end_walk;
                        :: else
                    fi;

                :: else
            fi;

            walk_component(nd, pathstring.pathname[comp_idx], walk_err);
            if
                :: walk_err != 0 -> 
                    goto end_walk;
                :: else
            fi;

            // symlink check
            if 
                :: dtree.dentries[nd.dentry_t].d_symlink == true ->
                    trailing_symlink(nd, pathstring, comp_idx);
                    comp_idx = 0;
                :: else ->
                    comp_idx++;
            fi;
        :: else -> break;
    od;

end_walk:
    error = walk_err;
}

// lookup_last
inline last_component(nd, pathstring, error)
{
    short comp_idx = pathstring.length;
    error = 0;

    walk_component(nd, pathstring.pathname[comp_idx], error);
    if
        :: error != 0 -> 
            goto end_walk;
        :: else
    fi;

    // symlink check
    if
        :: dtree.dentries[nd.dentry_t].d_symlink == true ->
            trailing_symlink(nd, pathstring, comp_idx);
            goto end_symlink;
        :: else
    fi;

end_walk:
    nd.done = true;

end_symlink:
}

inline complete_walk(task, nd, flag, returnval, complete_err) 
{
    complete_err = 0;
    returnval = nd.dentry_t;
}

inline path_lookup(task, pathstring, flag, returnval, look_err)
{
    nameidata nd;
    look_err = 0;
    
    // init nd
    if 
        :: pathstring.length == -1 -> 
            goto end_lookup;
        :: else ->
            nd.done = false;
    fi;

    if 
        :: pathstring.pathname[0].string == 0 ->
            nd.root = task.root;
            nd.dentry_t = task.root;
            // the path is root
            if 
                :: pathstring.length == 0 ->
                    returnval = 0;
                    goto end_lookup;
                :: else
            fi;

        :: else ->
            nd.root = task.cwd;
            nd.dentry_t = task.cwd;
    fi;
    
    do
        :: nd.done == false ->
            link_path_walk(nd, pathstring, look_err);
            last_component(nd, pathstring, look_err);
        :: else -> break;
    od;

    complete_walk(task, nd, flag, returnval, look_err);

end_lookup:
}

// root is a "short" that means a "dentry"
inline init_rendering(task, croot)
{
    bit mnt_tag = task.mnt_ns.id;
    
    // walk dentry tree (dcache): deep search
    short node[MAXDENTRY];
    short node_len = 0;
    short idx;
    for (idx : 0 .. MAXDENTRY - 1) {
        node[idx] = -1;
    }
    
    idx = 0;            // init again after for loop
    node[0] = croot;
    do  
        :: idx < MAXDENTRY && node[idx] != -1 ->
            short s_idx = 0;
            short ct = node[idx];
            do
                :: s_idx <= dtree.dentries[ct].sub_index ->
                    node_len++;
                    node[node_len] = dtree.dentries[ct].d_subdirs[s_idx];
                    s_idx++;
                :: else ->
                    idx++;
                    break;
            od;
        :: else -> break;
    od;

    // tag
    short did;
    for (idx : 0 .. node_len) {
        did = node[idx];
        if 
            :: did >= 0 ->
                // printf("[WARN] init_rendering, dentry: %d[%d], name: %d[p: %d]\n", did, task.mnt_ns.id, dtree.dentries[did].name.string, dtree.dentries[did].d_parent);
                dtree.dentries[did].d_mntns.id = task.mnt_ns.id;
            :: else
        fi;
    }
}

//===================================================
//              vfs-related system call
//===================================================
inline sys_open(task, pathstring, flag, rtv, open_err)
{
    atomic{
        short target_dent;
        short look_err = 0;

        path_lookup(task, pathstring, flag, rtv, look_err);
        // printf("[INFO] path_lookup returnval: %d[name: %d]\n", rtv, dtree.dentries[rtv].name.string);
        if 
            :: look_err == ENOENT && flag == O_CREAT ->
                short parent = rtv;
                short name_s = pathstring.pathname[pathstring.length].string;
                patharray symarray;         // default is false
                short mntns_id = task.mnt_ns.id;
                short alloc_err = 0;
                d_alloc(parent, name_s, symarray, mntns_id, rtv, alloc_err);

                if 
                    // cannot alloc dentry
                    :: alloc_err != 0 -> 
                        open_err = ENOMEM;
                        rtv = -1;
                    :: else
                fi;
            :: else ->
                if 
                    :: look_err != 0 ->
                        open_err = look_err;
                        rtv = -1;
                    :: else
                fi;
        fi;
    }
}

inline sys_chroot(task, pathstring, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 || dtree.dentries[src_dentry].invalid == false ->
                task.root = dest_dentry;
                init_rendering(task, task.root);
            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_symlink(task, src, dest, error)
{
    atomic{
        short src_dentry;
        short sys_sym_err = 0;
        
        path_lookup(task, src, 0, src_dentry, sys_sym_err);
        if 
            :: sys_sym_err == 0 ->
                dtree.dentries[src_dentry].d_symlink = true;
                equal_pathstring(dest, dtree.dentries[src_dentry].d_symname);
            :: else -> 
                error = sys_sym_err;
        fi;
    }
}

inline sys_stat(task, pathstring, rtv, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 || dtree.dentries[dest_dentry].invalid == false ->
                rtv = dtree.dentries[dest_dentry].d_symlink;
            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_lstat(task, pathstring, rtv, error)
{
    atomic{
        short target_dent;
        short look_err = 0;
        patharray parent_path;

        equal_pathstring(pathstring, parent_path);
        parent_path.length = parent_path.length - 1;
        if
            :: parent_path.length < 0 ->
                rtv = -1;
            :: else ->
                path_lookup(task, parent_path, 0, rtv, look_err);
        fi;

        if 
            :: rtv >= 0 && dtree.dentries[rtv].invalid == false ->
                // judge conflict
                short sub_idx = 0;
                short subdir_num;
                short sub_dent_idx;
                bool match = false;

                subdir_num = dtree.dentries[rtv].sub_index;
                do
                    :: sub_idx <= subdir_num ->
                        sub_dent_idx = dtree.dentries[rtv].d_subdirs[sub_idx];
                        if 
                            ::  dtree.dentries[sub_dent_idx].name.string == pathstring.pathname[pathstring.length].string && dtree.dentries[sub_dent_idx].invalid == false ->
                                match = true;
                                rtv = sub_dent_idx;
                                break;
                            :: else ->
                                sub_idx++;
                        fi;
                    :: else -> break;
                od;

                if 
                    :: match == false ->
                        rtv = -1;
                        error = ENOENT;
                    :: else
                fi;

            :: else ->
                rtv = -1;
                error = ENOENT;
        fi;
    }
}

inline sys_access(task, pathstring, rtv)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                rtv = 0;
            :: else -> 
                rtv = ENOENT;
        fi;
    }
}

inline sys_execve(task, pathstring, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, FMODE_EXEC, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                error = 0;
            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_rename(task, pathstring, newname, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                // judge conflict
                short sub_idx = 0;
                short subdir_num;
                short sub_dent_idx;
                bool match = false;

                subdir_num = dtree.dentries[dtree.dentries[dest_dentry].d_parent].sub_index;
                do
                    :: sub_idx <= subdir_num ->
                        sub_dent_idx = dtree.dentries[dtree.dentries[dest_dentry].d_parent].d_subdirs[sub_idx];
                        if 
                            ::  dtree.dentries[sub_dent_idx].name.string == newname && dtree.dentries[sub_dent_idx].invalid == false ->
                                match = true;
                                break;
                            :: else -> 
                                sub_idx++;
                        fi;
                    :: else -> break;
                od;

                // name conflict
                if 
                    :: match == true ->
                        error = ENOENT;
                    :: else ->
                        dtree.dentries[dest_dentry].name.string = newname;
                fi;

            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_mkdir(task, pathstring, rtv, error)
{
    atomic{
        short target_dent;
        short look_err = 0;
        patharray parent_path;

        // find the parent first
        equal_pathstring(pathstring, parent_path);
        parent_path.length = parent_path.length - 1;
        if
            :: parent_path.length < 0 ->
                rtv = -1;
            :: else ->
                path_lookup(task, parent_path, 0, rtv, look_err);
        fi; 

        if 
            :: rtv >= 0 && dtree.dentries[rtv].invalid == false ->
                // judge conflict
                short sub_idx = 0;
                short subdir_num;
                short sub_dent_idx;
                bool match = false;

                subdir_num = dtree.dentries[rtv].sub_index;
                do
                    :: sub_idx <= subdir_num ->
                        sub_dent_idx = dtree.dentries[rtv].d_subdirs[sub_idx];
                        if 
                            :: dtree.dentries[sub_dent_idx].name.string == pathstring.pathname[pathstring.length].string && dtree.dentries[sub_dent_idx].invalid == false ->
                                match = true;
                                break;
                            :: else ->
                                sub_idx++;
                        fi;
                    :: else -> break;
                od;

                if 
                    :: match == true -> // name conflict
                        error = ENOENT;
                    :: else ->
                        short parent = rtv;
                        short name_s = pathstring.pathname[pathstring.length].string;
                        patharray symarray;         // default is false
                        short mntns_id = dtree.dentries[parent].d_mntns;
                        short alloc_err = 0;
                        d_alloc(parent, name_s, symarray, mntns_id, rtv, alloc_err);
                        if 
                            // cannot alloc dentry
                            :: alloc_err != 0 -> 
                                error = ENOMEM;
                                rtv = -1;
                            :: else
                        fi;
                fi;

            :: else ->
                rtv = -1;
                error = ENOENT;
        fi;
    }
}

inline sys_rmdir(task, pathstring, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                dtree.dentries[dest_dentry].invalid = true;
            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_readlink(task, pathstring, rtv, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                if 
                    :: dtree.dentries[dest_dentry].d_symlink == true ->
                        rtv = dtree.dentries[dest_dentry].d_symname;
                    :: else ->
                        error = ENOENT;
                fi;
            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_mount(task, pathstring, rtv)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                rtv = true;
            :: else -> 
                rtv = false;
        fi;
    }
}

inline sys_unmount(task, pathstring, rtv)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                rtv = true;
            :: else -> 
                rtv = false;
        fi;
    }
}

inline sys_uselib(task, pathstring, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, FMODE_EXEC, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                error = 0;
            :: else -> 
                error = ENOENT;
        fi;
    }
}

inline sys_chdir(task, pathstring, error)
{
    atomic{
        short dest_dentry;

        path_lookup(task, pathstring, 0, dest_dentry, error);
        if 
            :: dest_dentry >= 0 && dtree.dentries[dest_dentry].invalid == false ->
                task.cwd = dest_dentry;
            :: else -> 
                error = ENOENT;
        fi;
    }
}

//===================================================
//              model checking
//===================================================
// model checking functions
inline create_host_task()
{
    short root_dentry;
    short c_err = 0;
    short name_string = 0;
    patharray symarray;
    host_ns.id = 0;

    // create rootfs
    d_alloc(-1, name_string, symarray, host_ns.id, root_dentry, c_err);
    if 
        :: root_dentry != -1 && c_err == 0 ->
            host_t.root = root_dentry;
            host_t.cwd = root_dentry;
        :: else
    fi;

    host_t.mnt_ns.id = host_ns.id;
}

inline create_container_task(rootpath)
{
    short error = 0;
    container_ns.id = 1;

    container_t.mnt_ns.id = container_ns.id;
    sys_chroot(container_t, rootpath, error);
    container_t.cwd = container_t.root;
}

inline generateRealPaths()
{
    // root path init
    allPaths[0].pathname[0].string = 0;
    allPaths[0].length = 0;
    path_num = 0;

    // printf("[1] starting generate path\n");

    short pathlen;
    for (pathlen: 1 .. MAXPATHLEGTH - 1){
        short i = -1;
        short current_path_num = path_num;
        do  
            :: i <= current_path_num ->
                i++;
                if
                    :: allPaths[i].length == pathlen - 1 ->
                        short name;
                        for (name: 1 .. MAXSUBDIR - 1){ // pass the root "0"
                            path_num++;
                            if
                                :: path_num >= MAXPATHNUM -> 
                                    break;
                                :: else
                            fi;

                            equal_pathstring(allPaths[i], allPaths[path_num]);
                            allPaths[path_num].length++;
                            allPaths[path_num].pathname[pathlen].string = name;

                            // create dentry
                            short create_err = 0;
                            short rtv_dentry;
                            sys_open(host_t, allPaths[path_num], O_CREAT, rtv_dentry, create_err);

                            //test: print path
                            // printPath(allPaths[path_num]);
                        }

                        if
                            :: path_num >= MAXPATHNUM -> 
                                break;
                            :: else
                        fi;
                    :: else
                fi;
            :: else -> break;
        od;
        if
            :: path_num >= MAXPATHNUM -> 
                break;
            :: else
        fi;
    }
}

// "destscope" describe the required mnt scope
inline assertionOpen(task, goalpath)
{
    atomic{
        short open_err;
        short rtv;

        sys_open(task, goalpath.destpath, O_CREAT, rtv, open_err);
        if
            :: open_err == 0 && rtv >= 0 ->
                assert(dtree.dentries[rtv].d_mntns.id == goalpath.destscope);
            :: else
        fi;
    }

    atomic{
        short open_err;
        short rtv;
        sys_open(task, goalpath.destpath, FMODE_EXEC, rtv, open_err);
        if
            :: open_err == 0 && rtv >= 0 ->
                assert(dtree.dentries[rtv].d_mntns.id == goalpath.destscope);
            :: else
        fi;
    }
}

proctype hostProcess()
{
    short err = 0;
    short rtv = -1;
    patharray sensitive;
    sensitive.pathname[0].string = 0;
    sensitive.length = 0;

    do
        :: stopsign == 0 ->
            assertionOpen(host_t, host_path);
            
            sys_chroot(host_t, host_path.destpath, err);
            sys_symlink(host_t, host_path.destpath, sensitive, err);
            sys_stat(host_t, host_path.destpath, rtv, err);
            sys_lstat(host_t, host_path.destpath, rtv, err);
            sys_access(host_t, host_path.destpath, err);
            sys_execve(host_t, host_path.destpath, err);
            sys_rename(host_t, host_path.destpath, 900, err);
            sys_mkdir(host_t, host_path.destpath, rtv, err);
            sys_rmdir(host_t, host_path.destpath, err);
            sys_readlink(host_t, host_path.destpath, rtv, err);
            sys_mount(host_t, host_path.destpath, err);
            sys_unmount(host_t, host_path.destpath, err);
            sys_uselib(host_t, host_path.destpath, err);
            sys_chdir(host_t, host_path.destpath, err);
            
            stopsign = 1;

        :: else -> break;
    od;
}

proctype containerProcess()
{
    // "destination" is the current path that the host wants to access
    short err = 0;
    short rtv = -1;
    patharray sensitive;
    sensitive.pathname[0].string = 0;
    sensitive.length = 0;

    do
        :: stopsign == 0 ->
            assertionOpen(container_t, cont_path);
            
            sys_chroot(container_t, cont_path.destpath, err);
            sys_symlink(container_t, cont_path.destpath, sensitive, err);
            sys_stat(container_t, cont_path.destpath, rtv, err);
            sys_lstat(container_t, cont_path.destpath, rtv, err);
            sys_access(container_t, cont_path.destpath, err);
            sys_execve(container_t, cont_path.destpath, err);
            sys_rename(container_t, cont_path.destpath, 900, err);
            sys_mkdir(container_t, cont_path.destpath, rtv, err);
            sys_rmdir(container_t, cont_path.destpath, err);
            sys_readlink(container_t, cont_path.destpath, rtv, err);
            sys_mount(container_t, cont_path.destpath, err);
            sys_unmount(container_t, cont_path.destpath, err);
            sys_uselib(container_t, cont_path.destpath, err);
            sys_chdir(container_t, cont_path.destpath, err);
            
            stopsign = 1;

        :: else -> break;
    od;
}

inline vfsInit()
{
    // create rootfs
    create_host_task();
    generateRealPaths();
    create_container_task(allPaths[2]);
}

init
{
    printf("[INFO] Starting to check.\n");
    
    vfsInit();
    
    // allPaths[96] is "/0/2/3/6"
    // allPaths[2] is "/0/2" that is the root of container

    // HOST will access the path "allPaths[96]" in container
    equal_pathstring(allPaths[96], host_path.destpath);
    host_path.destscope = 1;

    // CONTAINER will access the same path in the container
    short transformErr = 0;
    transformHost2Container(allPaths[2], allPaths[96], cont_path.destpath, transformErr);
    cont_path.destscope = 1;
    if
        :: transformErr != 0 ->
            printf("[ERROR] transform failed!\n");
            goto init_end;
        :: else
    fi;

    // start to check
    run hostProcess();
    run containerProcess();

init_end:
}