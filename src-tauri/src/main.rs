#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter};

static JOB: Mutex<()> = Mutex::new(());

#[derive(Serialize)]
struct AppInfo {
    mode: String,
    version: String,
    admin: bool,
    installed: bool,
    #[serde(rename = "installPath")]
    install_path: String,
    exe: String,
}

fn launch_mode() -> String {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--uninstall") {
        return "uninstall".into();
    }
    if args.iter().any(|arg| arg == "--setup") {
        return "setup".into();
    }
    if let Ok(path) = std::env::current_exe() {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if name.contains("setup") {
            return "setup".into();
        }
    }
    "app".into()
}

fn powershell(script: &str) -> Result<String, String> {
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .creation_flags(0x0800_0000)
        .output()
        .map_err(|error| error.to_string())?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !output.status.success() {
        return Err(if stderr.is_empty() { stdout } else { stderr });
    }
    Ok(stdout)
}

fn is_admin() -> bool {
    powershell("([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)")
        .map(|value| value.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn install_dir() -> PathBuf {
    PathBuf::from(r"C:\Program Files\Loom")
}

fn is_installed() -> bool {
    powershell("if (Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Loom') { 'yes' } else { 'no' }")
        .map(|value| value == "yes")
        .unwrap_or(false)
}

fn runtime_dir() -> PathBuf {
    let base = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().to_string());
    PathBuf::from(base).join("Loom").join("runtime")
}

fn write_runtime_file(path: &Path, contents: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::write(path, contents).map_err(|error| error.to_string())
}

fn materialize() -> Result<PathBuf, String> {
    let root = runtime_dir();
    write_runtime_file(&root.join("engine").join("Loom.ps1"), include_str!("../resources/engine/Loom.ps1"))?;
    write_runtime_file(
        &root.join("engine").join("autounattend.xml"),
        include_str!("../resources/engine/autounattend.xml"),
    )?;
    write_runtime_file(
        &root.join("config").join("applications.json"),
        include_str!("../resources/config/applications.json"),
    )?;
    write_runtime_file(&root.join("config").join("tweaks.json"), include_str!("../resources/config/tweaks.json"))?;
    write_runtime_file(&root.join("config").join("feature.json"), include_str!("../resources/config/feature.json"))?;
    write_runtime_file(&root.join("config").join("preset.json"), include_str!("../resources/config/preset.json"))?;
    write_runtime_file(&root.join("config").join("dns.json"), include_str!("../resources/config/dns.json"))?;
    write_runtime_file(&root.join("config").join("appx.json"), include_str!("../resources/config/appx.json"))?;
    Ok(root)
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[tauri::command]
fn app_info() -> AppInfo {
    let exe = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    AppInfo {
        mode: launch_mode(),
        version: env!("CARGO_PKG_VERSION").into(),
        admin: is_admin(),
        installed: is_installed(),
        install_path: install_dir().display().to_string(),
        exe,
    }
}

#[tauri::command]
fn elevate(mode: String) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    let arg = match mode.as_str() {
        "setup" => "--setup",
        "uninstall" => "--uninstall",
        _ => "",
    };
    let script = format!(
        "Start-Process -FilePath {} -ArgumentList {} -Verb RunAs",
        quote(&exe.display().to_string()),
        quote(arg)
    );
    powershell(&script)?;
    std::process::exit(0);
}

#[tauri::command]
fn install_loom(desktop: bool, start_menu: bool) -> Result<String, String> {
    if !is_admin() {
        return Err("Installer needs administrator approval.".into());
    }
    let source = std::env::current_exe().map_err(|error| error.to_string())?;
    let folder = install_dir();
    fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    let target = folder.join("Loom.exe");
    if source != target {
        fs::copy(&source, &target).map_err(|error| format!("Could not copy Loom: {error}"))?;
    }
    let target_text = target.display().to_string();
    let folder_text = folder.display().to_string();
    let mut script = format!(
        r#"
$shell = New-Object -ComObject WScript.Shell
$exe = {target}
$dir = {folder}
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' DisplayName 'Loom'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' DisplayVersion '1.0.0'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' Publisher 'Loom'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' InstallLocation $dir
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' DisplayIcon $exe
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' UninstallString "`"$exe`" --uninstall"
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' NoModify 1 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' NoRepair 1 -Type DWord
"#,
        target = quote(&target_text),
        folder = quote(&folder_text)
    );
    if start_menu {
        script.push_str(&format!(
            r#"
$start = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Loom.lnk'
$link = $shell.CreateShortcut($start)
$link.TargetPath = $exe
$link.WorkingDirectory = $dir
$link.Description = 'Loom'
$link.Save()
"#
        ));
    }
    if desktop {
        script.push_str(
            r#"
$desk = Join-Path $env:PUBLIC 'Desktop\Loom.lnk'
$link2 = $shell.CreateShortcut($desk)
$link2.TargetPath = $exe
$link2.WorkingDirectory = $dir
$link2.Description = 'Loom'
$link2.Save()
"#,
        );
    }
    powershell(&script)?;
    Ok(target_text)
}

#[tauri::command]
fn write_text(path: String, contents: String) -> Result<(), String> {
    let file = PathBuf::from(&path);
    if let Some(parent) = file.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
    }
    fs::write(file, contents).map_err(|error| error.to_string())
}

#[tauri::command]
fn uninstall_loom(app: AppHandle) -> Result<(), String> {
    if !is_admin() {
        return Err("Removing Loom needs administrator approval.".into());
    }
    let folder = install_dir();
    let _ = powershell(
        r#"
Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Loom' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Loom.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:PUBLIC 'Desktop\Loom.lnk') -Force -ErrorAction SilentlyContinue
"#,
    );
    let folder_text = folder.display().to_string();
    let _ = Command::new("cmd.exe")
        .args([
            "/C",
            &format!("ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"{folder_text}\""),
        ])
        .creation_flags(0x0800_0000 | 0x0000_0008)
        .spawn();
    app.exit(0);
    Ok(())
}

#[tauri::command]
async fn run_engine(app: AppHandle, action: String, payload: Value) -> Result<Value, String> {
    let app_handle = app.clone();
    tauri::async_runtime::spawn_blocking(move || run_engine_blocking(app_handle, action, payload))
        .await
        .map_err(|error| error.to_string())?
}

fn run_engine_blocking(app: AppHandle, action: String, payload: Value) -> Result<Value, String> {
    let _guard = JOB
        .try_lock()
        .map_err(|_| "Loom is already working through another change.".to_string())?;
    let resources = materialize()?;
    let payload_path = std::env::temp_dir().join(format!("loom-{}.json", std::process::id()));
    fs::write(&payload_path, payload.to_string()).map_err(|error| error.to_string())?;
    let script = resources.join("engine").join("Loom.ps1");
    let mut child = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            &script.to_string_lossy(),
            "-Action",
            &action,
            "-Payload",
            &payload_path.to_string_lossy(),
            "-Resources",
            &resources.to_string_lossy(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(0x0800_0000)
        .spawn()
        .map_err(|error| format!("Could not start PowerShell: {error}"))?;

    let stderr = child.stderr.take();
    let stderr_handle = std::thread::spawn(move || {
        let mut text = String::new();
        if let Some(stderr) = stderr {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                text.push_str(&line);
                text.push('\n');
            }
        }
        text
    });

    let mut result: Option<Value> = None;
    if let Some(stdout) = child.stdout.take() {
        let reader = BufReader::new(stdout);
        for line in reader.lines().map_while(Result::ok) {
            if let Some(rest) = line.strip_prefix("RESULT\t") {
                result = serde_json::from_str(rest).ok();
            } else if let Some(rest) = line.strip_prefix("LOG\t") {
                let mut parts = rest.splitn(3, '\t');
                let level = parts.next().unwrap_or("INFO").to_string();
                let percent = parts.next().unwrap_or("-1").parse::<i32>().unwrap_or(-1);
                let message = parts.next().unwrap_or("").to_string();
                let _ = app.emit(
                    "engine-log",
                    serde_json::json!({ "level": level, "percent": percent, "message": message }),
                );
            } else if !line.trim().is_empty() {
                let _ = app.emit(
                    "engine-log",
                    serde_json::json!({ "level": "INFO", "percent": -1, "message": line }),
                );
            }
        }
    }

    let status = child.wait().map_err(|error| error.to_string())?;
    let stderr_text = stderr_handle.join().unwrap_or_default();
    let _ = fs::remove_file(&payload_path);
    if let Some(result) = result {
        return Ok(result);
    }
    if !stderr_text.trim().is_empty() {
        return Err(stderr_text.trim().to_string());
    }
    Err(format!("The action ended without a result (exit {}).", status))
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            app_info,
            elevate,
            install_loom,
            uninstall_loom,
            write_text,
            run_engine
        ])
        .run(tauri::generate_context!())
        .expect("Loom failed to start");
}
