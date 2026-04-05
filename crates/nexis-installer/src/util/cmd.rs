use std::process::{Command, Output};

use anyhow::{bail, Context, Result};

/// Run a command and return its output; fail on non-zero exit.
pub fn run(program: &str, args: &[&str]) -> Result<Output> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("failed to execute {program}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("{program} exited with {}: {stderr}", output.status);
    }

    Ok(output)
}

/// Run a command and capture stdout as a trimmed string.
pub fn run_stdout(program: &str, args: &[&str]) -> Result<String> {
    let output = run(program, args)?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Run a command, piping `input` to stdin.
pub fn run_with_stdin(program: &str, args: &[&str], input: &str) -> Result<Output> {
    use std::io::Write;
    use std::process::Stdio;

    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to spawn {program}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(input.as_bytes())
            .context("failed to write to stdin")?;
    }

    let output = child.wait_with_output()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("{program} exited with {}: {stderr}", output.status);
    }

    Ok(output)
}
