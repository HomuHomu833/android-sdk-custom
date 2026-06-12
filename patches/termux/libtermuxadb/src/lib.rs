use std::{
    os::unix::{net::UnixDatagram, prelude::{RawFd, AsRawFd, FromRawFd, OsStrExt}},
    thread, process::{Command, ExitStatus}, time::Duration, io, str, env, sync::Mutex,
    path::{PathBuf, Path}, collections::{HashMap, BTreeSet}, ffi::{OsStr, CStr},
    mem, ptr::null_mut, cmp::Ordering
};

use anyhow::Context;
use libc::{
    DIR, dirent, c_char, c_int, fcntl, F_GETFD, F_SETFD, FD_CLOEXEC, c_uchar, c_ushort, DT_CHR, DT_DIR, O_CREAT, strcmp
};

use nix::{unistd::{lseek, Whence}, sys::{stat::fstat, memfd::{memfd_create, MemFdCreateFlag}}, fcntl::readlink};
use once_cell::sync::Lazy;
use rand::Rng;
use rusb::{constants::LIBUSB_OPTION_NO_DEVICE_DISCOVERY, UsbContext};
use sendfd::{SendWithFd, RecvWithFd};
use which::which;

use log::{debug, info, error, warn};

enum HookedDir {
    Native(*mut DIR),
    Virtual(DirStream)
}

impl From<HookedDir> for *mut DIR {
    fn from(hd: HookedDir) -> Self {
        Box::into_raw(Box::new(hd)) as Self
    }
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_opendir(name: *const c_char) -> *mut DIR {
    if name.is_null() {
        return libc::opendir(name);
    }

    let name_cstr = CStr::from_ptr(name);
    let name_str = to_string(name_cstr);

    if name_str.starts_with(BASE_DIR_ORIG) {
        let name_osstr = to_os_str(name_cstr);
        if let Some(dir_entries) = DIR_MAP.lock().unwrap().get(&PathBuf::from(name_osstr)) {
            debug!("called opendir with {}, remapping to virtual DirStream", &name_str);
            return HookedDir::Virtual(DirStream::from(dir_entries)).into();
        }
    }

    debug!("called opendir with {}", &name_str);
    let dir = libc::opendir(name);
    if dir.is_null() {
        return null_mut();
    }
    HookedDir::Native(dir).into()
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_closedir(dirp: *mut DIR) -> c_int {
    debug!("called closedir with dirp {:?}", dirp);
    if dirp.is_null() {
        return libc::closedir(dirp);
    }

    let hooked_dir = Box::from_raw(dirp as *mut HookedDir);
    match hooked_dir.as_ref() {
        &HookedDir::Native(dirp) => {
            debug!("closedir: dirp is native DIR* {:?}", dirp);
            libc::closedir(dirp)
        }
        // nothing to do, hooked_dir along with DirStream
        // will be dropped at the end of this function
        &HookedDir::Virtual(_) => {
            debug!("closedir: dirp is virtual DirStream");
            0
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_readdir(dirp: *mut DIR) -> *mut dirent {
    debug!("called readdir with dirp {:?}", dirp);
    if dirp.is_null() {
        return libc::readdir(dirp);
    }

    let hooked_dir = &mut *(dirp as *mut HookedDir);
    match hooked_dir {
        &mut HookedDir::Native(dirp) => {
            debug!("readdir: dirp is native DIR* {:?}", dirp);
            let result = libc::readdir(dirp);
            if let Some(r) = result.as_ref() {
                debug!("readdir returned dirent {:?} with d_name={}", result, to_string(to_cstr(&r.d_name)));
            }
            result
        }
        &mut HookedDir::Virtual(DirStream{ref mut pos, ref mut entry}) => {
            debug!("readdir: dirp is virtual DirStream");
            let idx = *pos as usize;
            if idx < entry.len() {
                *pos += 1;
                let result = &mut entry[idx] as *mut dirent;
                debug!("readdir returned dirent {:?} with d_name={}", result, to_string(to_cstr(&entry[idx].d_name)));
                result
            } else {
                null_mut()
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_open(path: *const c_char, opts: c_int) -> c_int {
    open(path, opts, 0)
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_create(path: *const c_char, opts: c_int, mode: c_int) -> c_int {
    open(path, opts, mode)
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_close(_fd: c_int) -> c_int {
    // this is called from a patched adb and it's always no-op
    0
}

#[no_mangle]
pub unsafe extern "C" fn termuxadb_start() {
    env_logger::init();

    thread::spawn(|| {
        if let Err(e) = start() {
            error!("{}", e);
        }
    });
}

#[no_mangle]
pub unsafe extern "C" fn fastboot_start() {
    env_logger::init();

    if let Err(e) = authorize_connected_devices() {
        error!("{}", e);
    }
}

#[no_mangle]
pub extern "C" fn termuxadb_sendfd() -> bool {
    match (env::var("TERMUX_USB_DEV"), env::var("TERMUX_USB_FD"), env::var("TERMUX_ADB_SOCK_FD")) {
        (Ok(termux_usb_dev), Ok(termux_usb_fd), Ok(sock_send_fd)) => {
            if let Err(e) = sendfd_to_adb(&termux_usb_dev, &termux_usb_fd, &sock_send_fd) {
                error!("{}", e)
            }
            true
        }
        _ => false
    }
}

fn get_termux_fd(path: &Path) -> Option<RawFd> {
    USB_FD_MAP.lock().unwrap().get(path).map(|fd| *fd)
}

fn get_usb_device_serial(path: &Path) -> Option<String> {
    USB_SERIAL_MAP.lock().unwrap().get(path).map(|sn| sn.to_owned())
}

fn to_string(s: &CStr) -> String {
    s.to_string_lossy().into_owned()
}

fn to_os_str(s: &CStr) -> &OsStr {
    OsStr::from_bytes(s.to_bytes())
}

fn to_cstr(b: &[c_char]) -> &CStr {
    unsafe { CStr::from_ptr(b.as_ptr()) }
}

unsafe fn open(pathname: *const c_char, flags: c_int, mode: c_int) -> c_int {
    if !pathname.is_null() {
        let name = to_string(CStr::from_ptr(pathname));

        debug!("called open with pathname={} flags={}", name, flags);

        let name_path = PathBuf::from(&name);
        if let Some(usb_fd) = get_termux_fd(&name_path) {
            if let Err(e) = lseek(usb_fd, 0, Whence::SeekSet) {
                error!("error seeking fd {}: {}", usb_fd, e);
            }
            info!("open hook returning fd with value {}", usb_fd);
            return usb_fd;
        }

        if let Some(usb_serial) = get_usb_device_serial(&name_path) {
            if let Ok(serial_fd) = memfd_create(
                CStr::from_ptr("usb-serial\0".as_ptr() as *const c_char),
                MemFdCreateFlag::empty())
            {
                let wr_status = nix::unistd::write(
                    serial_fd, usb_serial.as_bytes());
                let seek_status = lseek(serial_fd, 0, Whence::SeekSet);

                match (wr_status, seek_status) {
                    (Ok(_), Ok(_)) => {
                        info!("open hook returning fd with value {}", serial_fd);
                        return serial_fd
                    }
                    _ => ()
                }
            }
        }
    }

    let result = if (flags & O_CREAT) == 0 {
        libc::open(pathname, flags)
    } else {
        libc::open(pathname, flags, mode)
    };

    debug!("open returned fd with value {}", result);

    result
}

fn sendfd_to_adb(termux_usb_dev: &str, termux_usb_fd: &str, sock_send_fd: &str) -> anyhow::Result<()> {
    let socket = unsafe{ UnixDatagram::from_raw_fd(sock_send_fd.parse()?) };
    // send termux_usb_dev and termux_usb_fd to adb-hooks
    match socket.send_with_fd(termux_usb_dev.as_bytes(), &[termux_usb_fd.parse()?]) {
        Ok(_) => {
            info!("found {}, sending fd {} to adb", &termux_usb_dev, &termux_usb_fd);
        }
        Err(e) => {
            error!("error sending usb fd to adb-hooks: {}", e);
        }
    }
    Ok(())
}

const REQUIRED_CMDS: [&str; 1] = ["termux-usb"];

fn check_dependencies() -> anyhow::Result<()> {
    for dep in REQUIRED_CMDS {
        _ = which(dep).context(format!("error: {} command not found", dep))?;
    }
    Ok(())
}

fn clear_cloexec_flag(socket: &UnixDatagram) -> RawFd {
    let sock_fd = socket.as_raw_fd();
    unsafe {
        let flags = fcntl(sock_fd, F_GETFD);
        fcntl(sock_fd, F_SETFD, flags & !FD_CLOEXEC);
    }
    sock_fd
}

fn get_termux_usb_list() -> Vec<String> {
    if let Ok(out) = Command::new("termux-usb").arg("-l").output() {
        if let Ok(stdout) = str::from_utf8(&out.stdout) {
            if let Ok(lst) = serde_json::from_str(stdout) {
                return lst;
            }
        }
    }
    vec![]
}

fn run_under_termux_usb(usb_dev_path: &str, cmd_path: &Path, sock_send_fd: RawFd) -> io::Result<ExitStatus> {
    let mut cmd = Command::new("termux-usb");

    cmd.env("TERMUX_USB_DEV", usb_dev_path)
        .arg("-e").arg(cmd_path)
        .args(["-E", "-r", usb_dev_path]);

    cmd.env("TERMUX_ADB_SOCK_FD", sock_send_fd.to_string());
    return cmd.status();
}

fn request_usb_fds(socket: &UnixDatagram, cmd_path: &Path, usb_dev_list: &Vec<String>, last_usb_list: &Vec<String>) {
    let mut usb_dev_list_iter = usb_dev_list.iter();
    while let Some(usb_dev_path) = usb_dev_list_iter.next() {
        if last_usb_list.iter().find(|&dev| dev == usb_dev_path) == None {
            info!("new device connected: {}", usb_dev_path);
            _ = run_under_termux_usb(&usb_dev_path, cmd_path, socket.as_raw_fd());
        }
    }
}

fn scan_for_usb_devices(socket: UnixDatagram, termux_adb_path: &Path) {
    let mut last_usb_list = vec![];

    loop {
        let usb_dev_list = get_termux_usb_list();
        request_usb_fds(&socket, termux_adb_path, &usb_dev_list, &last_usb_list);

        if last_usb_list.len() > 0 && usb_dev_list.len() == 0{
            info!("all devices disconnected");
        }

        last_usb_list = usb_dev_list;
        thread::sleep(Duration::from_millis(2000));
    }
}

fn authorize_connected_devices() -> anyhow::Result<()> {
    check_dependencies()?;

    let (sock_send, sock_recv) =
    UnixDatagram::pair().context("could not create socket pair")?;

    // we need to unset FD_CLOEXEC flag so that the socket
    // can be passed to adb when it's run as child process
    _ = clear_cloexec_flag(&sock_send);

    let termux_fastboot_path = env::current_exe()
        .context("failed to get executable path")?;
    debug!("TERMUX_FASTBOOT_PATH={}", termux_fastboot_path.display());

    let usb_dev_list = get_termux_usb_list();
    let hnd = thread::spawn({
        let device_count = Some(usb_dev_list.len());
        move || start_socket_listener(sock_recv, device_count)
    });

    let last_usb_list = vec![];
    request_usb_fds(&sock_send, &termux_fastboot_path, &usb_dev_list, &last_usb_list);

    hnd.join().unwrap();

    Ok(())
}

fn start() -> anyhow::Result<()> {
    check_dependencies()?;

    let (sock_send, sock_recv) =
        UnixDatagram::pair().context("could not create socket pair")?;

    // we need to unset FD_CLOEXEC flag so that the socket
    // can be passed to adb when it's run as child process
    _ = clear_cloexec_flag(&sock_send);

    thread::spawn(move || start_socket_listener(sock_recv, None));

    let termux_adb_path = env::current_exe()
        .context("failed to get executable path")?;
    debug!("TERMUX_ADB_PATH={}", termux_adb_path.display());
    scan_for_usb_devices(sock_send, &termux_adb_path);

    Ok(())
}

#[derive(Clone)]
struct UsbSerial {
    number: String,
    path: PathBuf,
}

fn start_socket_listener(socket: UnixDatagram, device_count: Option<usize>) {
    info!("listening on socket");
    _ = socket.set_read_timeout(None);

    let mut limited;
    let mut unlimited;

    let loop_range: &mut dyn Iterator<Item=_> = match device_count {
        Some(count) => { limited = 0..count; &mut limited }
        None => { unlimited = 0..; &mut unlimited }
    };

    for _ in loop_range {
        let mut buf = vec![0; 256];
        let mut fds = vec![0; 1];
        match socket.recv_with_fd(buf.as_mut_slice(), fds.as_mut_slice()) {
            Ok((_, 0)) => {
                error!("received message without usb fd");
            }
            Ok((size, _)) => {
                let usb_dev_path = PathBuf::from(String::from_utf8_lossy(&buf[0..size]).as_ref());
                let usb_fd = fds[0];
                // use the received info as TERMUX_USB_DEV and TERMUX_USB_FD
                info!("received message (size={}) with fd={}: {}", size, usb_fd, usb_dev_path.display());

                update_dir_map(&mut DIR_MAP.lock().unwrap(), &usb_dev_path);
                USB_FD_MAP.lock().unwrap().insert(usb_dev_path, usb_fd);

                if let Some(ref usb_serial) = log_warning_and_convert(init_libusb_device_serial(usb_fd)) {
                    let mut usb_serial_map = USB_SERIAL_MAP.lock().unwrap();
                    usb_serial_map.insert(usb_serial.path.clone(), usb_serial.number.clone());
                    debug!("updated USB_SERIAL_MAP: {:?}", &*usb_serial_map);
                }
            }
            Err(e) => {
                error!("message receive error: {}", e);
            }
        }
    }
}

// our directory structure will always be flat
// so we can have just one dirent per DirStream
#[derive(Clone, Debug)]
struct DirStream {
    pos: i32,
    entry: Vec<dirent>,
}

impl From<&BTreeSet<DirEntry>> for DirStream {
    fn from(set: &BTreeSet<DirEntry>) -> Self {
        DirStream { pos: 0, entry: set.iter().map(|e| e.0).collect() }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DirEntry(dirent);

impl PartialOrd for DirEntry {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(match unsafe{ strcmp(self.0.d_name.as_ptr(), other.0.d_name.as_ptr()) } {
            res if res < 0 => Ordering::Less,
            res if res > 0 => Ordering::Greater,
            _ => Ordering::Equal,
        })
    }
}

impl Ord for DirEntry {
    fn cmp(&self, other: &Self) -> Ordering {
        self.partial_cmp(other).unwrap()
    }
}

static DIR_MAP: Lazy<Mutex<HashMap<PathBuf, BTreeSet<DirEntry>>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static USB_SERIAL_MAP: Lazy<Mutex<HashMap<PathBuf, String>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static USB_FD_MAP: Lazy<Mutex<HashMap<PathBuf, RawFd>>> = Lazy::new(|| Mutex::new(HashMap::new()));

const BASE_DIR_ORIG: &str = "/dev/bus/usb";

trait NameSetter {
    fn set_name(&mut self, name: &OsStr);
}

impl NameSetter for dirent {
    fn set_name(&mut self, name: &OsStr) {
        for (i, j) in self.d_name.iter_mut().zip(
            name.as_bytes().iter().chain([0].iter())
        ) {
            *i = *j as c_char;
        }
    }
}

fn dirent_new(off: i64, typ: c_uchar, name: &OsStr) -> dirent {
    let mut rng = rand::thread_rng();
    let mut entry = dirent {
        d_ino: rng.gen(),
        d_off: off,
        d_reclen: mem::size_of::<dirent>() as c_ushort,
        d_type: typ,
        d_name: [0; 256],
    };
    entry.set_name(name);

    entry
}

fn update_dir_map(dir_map: &mut HashMap<PathBuf, BTreeSet<DirEntry>>, usb_dev_path: &Path) {
    if let Some(usb_dev_name) = usb_dev_path.file_name() {
        let mut last_entry = DirEntry(dirent_new(
            0, DT_CHR, usb_dev_name
        ));
        let mut current_dir = usb_dev_path.to_owned();

        while current_dir.pop() {
            dir_map.entry(current_dir.clone())
                .and_modify(|entries| {
                    entries.insert(last_entry.clone());
                })
                .or_insert(BTreeSet::from([last_entry.clone()]));
            last_entry = DirEntry(dirent_new(
                0, DT_DIR, current_dir.file_name().unwrap()
            ));

            if current_dir.as_os_str() == BASE_DIR_ORIG {
                break;
            }
        }
    }
    debug!("updated DIR_MAP: {:?}", dir_map);
}

fn log_warning_and_convert<T>(r: anyhow::Result<T>) -> Option<T> {
    match r {
        Ok(v) => Some(v),
        Err(e) => {
            warn!("{}", e);
            None
        }
    }
}

fn init_libusb_device_serial(usb_fd: c_int) -> anyhow::Result<UsbSerial> {
    debug!("calling libusb_set_option");
    unsafe{ rusb::ffi::libusb_set_option(null_mut(), LIBUSB_OPTION_NO_DEVICE_DISCOVERY) };

    lseek(usb_fd, 0, Whence::SeekSet)
        .with_context(|| format!("error seeking fd: {}", usb_fd))?;

    let ctx = rusb::Context::new().context("libusb_init error")?;

    debug!("opening device from {}", usb_fd);
    let usb_handle = unsafe{
        ctx.open_device_with_fd(usb_fd).context("error opening device")
    }?;

    debug!("getting device from handle");
    let usb_dev = usb_handle.device();

    debug!("requesting device descriptor");
    let usb_dev_desc = usb_dev.device_descriptor()
        .context("error getting device descriptor")?;

    let vid = usb_dev_desc.vendor_id();
    let pid = usb_dev_desc.product_id();
    let iser = usb_dev_desc.serial_number_string_index();
    debug!("device descriptor: vid={}, pid={}, iSerial={}", vid, pid, iser.unwrap_or(0));

    let timeout = Duration::from_secs(1);
    let languages = usb_handle.read_languages(timeout)
        .context("error getting supported languages for reading string descriptors")?;

    let serial_number = usb_handle.read_serial_number_string(
        languages[0], &usb_dev_desc, timeout
    ).context("error reading serial number of the device")?;

    let st = fstat(usb_fd).context("error: could not stat TERMUX_USB_FD")?;
    let dev_path_link = format!("/sys/dev/char/{}:{}", major(st.st_rdev), minor(st.st_rdev));

    let dev_path = PathBuf::from(readlink(
    &PathBuf::from(&dev_path_link))
        .context(format!("error: could not resolve symlink {}", &dev_path_link)
    )?);

    let mut dev_serial_path = PathBuf::from("/sys/bus/usb/devices");

    dev_serial_path.push(dev_path.file_name().context("error: could not get device path")?);
    dev_serial_path.push("serial");

    info!("device serial path: {}", dev_serial_path.display());

    Ok(UsbSerial{ number: serial_number, path: dev_serial_path })
}


pub const fn major(dev: u64) -> u64 {
    ((dev >> 32) & 0xffff_f000) |
    ((dev >>  8) & 0x0000_0fff)
}

pub const fn minor(dev: u64) -> u64 {
    ((dev >> 12) & 0xffff_ff00) |
    ((dev      ) & 0x0000_00ff)
}
