module walfs::walfs {
    use std::string::{Self, String};
    use sui::dynamic_field as df;
    use sui::event;
    use sui::table;

    // 错误码定义
    const EEntryMisMatch: u64 = 1;
    const ENameAlreadyExists: u64 = 2;
    const EEntryNotFound: u64 = 3;
    const EInvalidEntryType: u64 = 4;
    const ENotEmptyFolder: u64 = 5;
    const ERootAlreadyExists: u64 = 6;

    // 目录项类型常量
    const FILE_TYPE: u8 = 0;
    const FOLDER_TYPE: u8 = 1;
    const LINK_TYPE: u8 = 2;

    // 公共元信息结构
    public struct Meta has store {
        created_at: u64,
        updated_at: u64,
    }

    // 文件对象
    public struct File has key {
        id: UID,
        meta: Meta,
        content: vector<u8>,
    }

    // 文件夹对象
    public struct Folder has key {
        id: UID,
        meta: Meta,
        entries: table::Table<String, DirEntry>,
        // 子项挂载于 DynamicField 上，结构为 name -> DirEntry
    }

    // 链接对象
    public struct Link has key {
        id: UID,
        meta: Meta,
        target_id: ID,
    }

    // 目录项映射结构
    public struct DirEntry has store {
        object_id: ID,
        // File, Folder, or Link
        entry_type: u8,
        // 0 = File, 1 = Folder, 2 = Link
    }

    // 根目录对象
    public struct Root has key, store {
        id: UID,
        name: String,
        folder_id: ID,
    }

    // 事件定义
    public struct FileCreatedEvent has copy, drop {
        file_id: ID,
        folder_id: ID,
        name: String,
        owner: address,
    }

    public struct FolderCreatedEvent has copy, drop {
        folder_id: ID,
        parent_id: Option<ID>,
        name: String,
        owner: address,
    }

    public struct LinkCreatedEvent has copy, drop {
        link_id: ID,
        folder_id: ID,
        name: String,
        target_id: ID,
        owner: address,
    }

    public struct EntryDeletedEvent has copy, drop {
        parent_id: ID,
        name: String,
        entry_type: u8,
    }

    public struct EntryRenamedEvent has copy, drop {
        parent_id: ID,
        old_name: String,
        new_name: String,
    }

    public struct RootCreatedEvent has copy, drop {
        root_id: ID,
        root_folder_id: ID,
        owner: address,
    }

    // === 元信息操作 ===
    fun create_meta(created_at: u64, updated_at: u64): Meta {
        Meta {
            created_at,
            updated_at,
        }
    }

    // 修改创建根目录的函数
    public entry fun create_root(name: String, ctx: &mut TxContext) {
        let owner = tx_context::sender(ctx);

        let ts = tx_context::epoch(ctx);

        let meta = create_meta(ts, ts);
        let folder = Folder {
            id: object::new(ctx),
            meta,
            entries: table::new<String, DirEntry>(ctx),
        };
        let folder_id = object::id(&folder);

        // 创建Root对象
        let root = Root {
            id: object::new(ctx),
            name,
            folder_id
        };

        let root_id = object::id(&root);

        // 发送事件
        event::emit(RootCreatedEvent {
            root_id,
            root_folder_id,
            owner,
        });

        // 转移Root对象给用户
        transfer::transfer(root, owner);
    }

    // === 文件操作 ===
    public entry fun create_file(
        parent: &mut Folder,
        name: String,
        content: vector<u8>,
        ctx: &mut TxContext
    ) {
        let caller = tx_context::sender(ctx);

        // 检查名称是否已存在
        assert!(!table::contains<String, DirEntry>(&parent.entries, name), ENameAlreadyExists);

        // 创建文件
        let ts = tx_context::epoch(ctx);
        let file = File {
            id: object::new(ctx),
            meta: create_meta(ts, ts),
            content,
        };

        let file_id = object::id(&file);

        // 添加到目录
        table::add(&mut parent.entries, name, DirEntry {
            object_id: file_id,
            entry_type: FILE_TYPE,
        });

        // 发送事件
        event::emit(FileCreatedEvent {
            file_id,
            folder_id: object::id(parent),
            name,
            owner: caller,
        });

        // 转移文件给用户
        transfer::transfer(file, caller);
    }


    // === 目录操作 ===
    public entry fun create_folder(
        parent: &mut Folder,
        name: String,
        ctx: &mut TxContext
    ) {
        let caller = tx_context::sender(ctx);

        // 检查名称是否已存在
        assert!(!table::contains(&parent.entries, name), ENameAlreadyExists);

        // 创建文件夹
        let ts = tx_context::epoch(ctx);
        let folder = Folder {
            id: object::new(ctx),
            meta: create_meta(ts, ts),
            entries: table::new<String, DirEntry>(ctx),
        };

        let folder_id = object::id(&folder);

        table::add(&mut parent.entries, name, DirEntry {
            object_id: folder_id,
            entry_type: FOLDER_TYPE,
        });

        // 发送事件
        event::emit(FolderCreatedEvent {
            folder_id,
            parent_id: option::some(object::id(parent)),
            name,
            owner: caller,
        });

        // 转移文件夹给用户
        transfer::transfer(folder, caller);
    }

    // === 链接操作 ===
    public entry fun create_link(
        folder: &mut Folder,
        name: String,
        target_id: ID,
        ctx: &mut TxContext
    ) {
        let caller = tx_context::sender(ctx);

        // 检查名称是否已存在
        assert!(!table::contains(&folder.entries, name), ENameAlreadyExists);

        // 创建链接
        let timestamp = tx_context::epoch(ctx);
        let link = Link {
            id: object::new(ctx),
            meta: create_meta(timestamp, timestamp),
            target_id,
        };

        let link_id = object::id(&link);

        // 添加到目录
        table::add(&mut folder.entries, name, DirEntry {
            object_id: link_id,
            entry_type: LINK_TYPE,
        });

        // 发送事件
        event::emit(LinkCreatedEvent {
            link_id,
            folder_id: object::id(folder),
            name,
            target_id,
            owner: caller,
        });

        // 转移链接给用户
        transfer::transfer(link, caller);
    }

    public entry fun delete_file(parent: &mut Folder, name: String, file: &mut File, ctx: &mut TxContext) {
        // 检查文件是否存在
        assert!(table::contains(&parent.entries, name), EEntryNotFound);

        // 获取目录项
        let DirEntry { object_id, entry_type } = table::remove(&mut parent.entries, name);

        // 确认是文件类型
        assert!(entry_type == FILE_TYPE, EInvalidEntryType);
        assert!(object_id == object::id(file), EEntryMisMatch);
        // 删除文件对象
        object::delete(object_id);

        // 发送事件
        event::emit(EntryDeletedEvent {
            parent_id: object::id(parent),
            name,
            entry_type: FILE_TYPE,
        });
    }

    public entry fun delete_folder(parent: &mut Folder, name: String, folder: &mut Folder, ctx: &mut TxContext) {
        assert!(table::contains(&parent.entries, name), EEntryNotFound);
        // 检查文件夹是否为空
        assert!(table::is_empty(&folder.entries), ENotEmptyFolder);

        // 检查文件夹是否存在
        let DirEntry { object_id, entry_type } = table::remove(&mut parent.entries, name);
        assert!(entry_type == FOLDER_TYPE, EInvalidEntryType);
        assert!(object_id == object::id(folder), EEntryMisMatch);

        object::delete(object_id);

        event::emit(EntryDeletedEvent {
            parent_id: object::id(parent),
            name,
            entry_type: FOLDER_TYPE,
        })
    }

    public entry fun delete_link(parent: &mut Folder, name: String, link: &mut Link, ctx: &mut TxContext) {
        assert!(table::contains(&parent.entries, name), EEntryNotFound);
        let DirEntry { object_id, entry_type } = table::remove(&mut parent.entries, name);
        assert!(entry_type == LINK_TYPE, EInvalidEntryType);
        assert!(object_id == object::id(link), EEntryMisMatch);
        object::delete(object_id);
        event::emit(EntryDeletedEvent {
            parent_id: object::id(parent),
            name,
            entry_type: LINK_TYPE,
        })
    }


    // === 通用操作 ===
    public entry fun rename_entry(
        folder: &mut Folder,
        old_name: String,
        new_name: String,
        ctx: &mut TxContext
    ) {
        // 检查旧名称是否存在
        assert!(table::contains(&folder.entries, old_name), EEntryNotFound);

        // 检查新名称是否已存在
        assert!(!table::contains(&folder.entries, new_name), ENameAlreadyExists);

        // 获取目录项
        let dir_entry: DirEntry = df::remove(&mut folder.id, old_name);

        // 添加到新名称
        df::add(&mut folder.id, new_name, dir_entry);

        // 发送事件
        event::emit(EntryRenamedEvent {
            parent_id: object::id(folder),
            old_name,
            new_name,
        });
    }
}
