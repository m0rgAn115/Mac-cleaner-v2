use std::{env, fs, path::{Path, PathBuf}, sync::atomic::{AtomicUsize, Ordering}, thread, time::Instant};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Stats { pub files: u64, pub dirs: u64, pub links: u64, pub bytes: u64, pub selected: u64, pub selected_bytes: u64, pub errors: u64 }
impl Stats {
    fn add(&mut self, s: Self) {
        self.files += s.files; self.dirs += s.dirs; self.links += s.links;
        self.bytes += s.bytes; self.selected += s.selected;
        self.selected_bytes += s.selected_bytes; self.errors += s.errors;
    }
    fn file(&mut self, name: &str, size: u64) {
        self.files += 1; self.bytes += size;
        if (name.ends_with(".log") && size > 10240) || (name.ends_with(".cache") && size > 0) {
            self.selected += 1; self.selected_bytes += size;
        }
    }
}
fn scan(root: &Path) -> Stats {
    let mut s = Stats::default();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        s.dirs += 1;
        let entries = match fs::read_dir(dir) { Ok(v) => v, Err(_) => { s.errors += 1; continue } };
        for entry in entries {
            let entry = match entry { Ok(v) => v, Err(_) => { s.errors += 1; continue } };
            let name_os = entry.file_name();
            let name = name_os.to_string_lossy();
            if name == ".DS_Store" || name == ".protected" { continue }
            let kind = match entry.file_type() { Ok(v) => v, Err(_) => { s.errors += 1; continue } };
            if kind.is_symlink() { s.links += 1; }
            else if kind.is_dir() { pending.push(entry.path()); }
            else if kind.is_file() {
                match entry.metadata() { Ok(m) => s.file(&name, m.len()), Err(_) => s.errors += 1 }
            }
        }
    }
    s
}
pub fn scan_categories(root: &Path, workers: usize) -> std::io::Result<Stats> {
    if workers == 0 || workers > 64 { return Err(std::io::Error::other("workers must be 1..64")) }
    let mut roots = Vec::new();
    // Fixtures have category directories at the top level, just like independent scan roots.
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() { roots.push(entry.path()); }
    }
    roots.sort();
    let next = AtomicUsize::new(0);
    let mut total = Stats::default();
    thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..workers {
            let roots = &roots; let next = &next;
            handles.push(scope.spawn(move || {
                let mut s = Stats::default();
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= roots.len() { break }
                    s.add(scan(&roots[i]));
                }
                s
            }));
        }
        for handle in handles { total.add(handle.join().unwrap()); }
    });
    Ok(total)
}
#[allow(dead_code)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args().collect();
    let root = PathBuf::from(&args[1]);
    let workers: usize = args[2].parse()?;
    let started = Instant::now();
    let total = scan_categories(&root, workers)?;
    println!("{{\"files\":{},\"dirs\":{},\"links\":{},\"bytes\":{},\"selected\":{},\"selected_bytes\":{},\"errors\":{},\"scan_seconds\":{:.9}}}",
        total.files,total.dirs,total.links,total.bytes,total.selected,total.selected_bytes,total.errors,started.elapsed().as_secs_f64());
    Ok(())
}
