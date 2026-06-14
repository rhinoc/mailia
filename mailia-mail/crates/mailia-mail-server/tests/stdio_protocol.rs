use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc,
    time::Duration,
};

use serde_json::Value;

#[test]
fn invalid_json_returns_parse_error_and_keeps_connection_usable() {
    let AppServerProcess {
        mut child,
        mut stdin,
        line_rx,
        reader,
    } = spawn_app_server([]);

    writeln!(stdin, "{{not valid json").expect("write invalid request");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], "parse_error");
    assert_eq!(response["error"]["code"], "parse_error");

    writeln!(stdin, r#"{{"id":1,"method":"initialize","params":{{}}}}"#).expect("write initialize");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 1);
    assert_eq!(response["result"]["serverName"], "mailia-mail");

    writeln!(stdin, r#"{{"id":2,"method":"shutdown","params":{{}}}}"#).expect("write shutdown");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 2);
    assert_eq!(response["result"]["ok"], true);

    drop(stdin);
    let status = child.wait().expect("wait for app-server");
    assert!(status.success(), "app-server exited with {status}");
    reader.join().expect("join app-server stdout reader");
}

#[test]
fn saturated_queue_returns_retryable_overloaded_error() {
    let AppServerProcess {
        mut child,
        mut stdin,
        line_rx,
        reader,
    } = spawn_app_server([("MAILIA_APP_SERVER_MAX_IN_FLIGHT_REQUESTS", "0")]);

    writeln!(stdin, r#"{{"id":1,"method":"initialize","params":{{}}}}"#).expect("write initialize");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 1);
    assert_eq!(response["result"]["serverName"], "mailia-mail");

    writeln!(stdin, r#"{{"id":2,"method":"server/noop","params":{{}}}}"#).expect("write noop");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 2);
    assert_eq!(response["error"]["code"], "overloaded");
    assert_eq!(response["error"]["retryable"], true);

    writeln!(stdin, r#"{{"id":3,"method":"shutdown","params":{{}}}}"#).expect("write shutdown");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 3);
    assert_eq!(response["result"]["ok"], true);

    drop(stdin);
    let status = child.wait().expect("wait for app-server");
    assert!(status.success(), "app-server exited with {status}");
    reader.join().expect("join app-server stdout reader");
}

#[test]
fn invalid_params_return_invalid_request_and_keep_connection_usable() {
    let AppServerProcess {
        mut child,
        mut stdin,
        line_rx,
        reader,
    } = spawn_app_server([]);

    writeln!(stdin, r#"{{"id":1,"method":"initialize","params":{{}}}}"#).expect("write initialize");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 1);
    assert_eq!(response["result"]["serverName"], "mailia-mail");

    writeln!(
        stdin,
        r#"{{"id":2,"method":"message/list","params":{{"page":1}}}}"#
    )
    .expect("write invalid params");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 2);
    assert_eq!(response["error"]["code"], "invalid_request");
    assert!(
        response["error"]["message"]
            .as_str()
            .expect("error message")
            .contains("invalid params for `message/list`")
    );

    writeln!(stdin, r#"{{"id":3,"method":"shutdown","params":{{}}}}"#).expect("write shutdown");
    let response = read_response(&line_rx);
    assert_eq!(response["id"], 3);
    assert_eq!(response["result"]["ok"], true);

    drop(stdin);
    let status = child.wait().expect("wait for app-server");
    assert!(status.success(), "app-server exited with {status}");
    reader.join().expect("join app-server stdout reader");
}

struct AppServerProcess {
    child: Child,
    stdin: ChildStdin,
    line_rx: mpsc::Receiver<String>,
    reader: std::thread::JoinHandle<()>,
}

fn spawn_app_server<const N: usize>(envs: [(&str, &str); N]) -> AppServerProcess {
    let mut command = Command::new(env!("CARGO_BIN_EXE_mailia-mail"));
    command
        .args(["app-server", "--listen", "stdio://"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in envs {
        command.env(key, value);
    }

    let mut child = command.spawn().expect("spawn app-server");
    let stdin = child.stdin.take().expect("app-server stdin");
    let stdout = child.stdout.take().expect("app-server stdout");
    let (line_tx, line_rx) = mpsc::channel();

    let reader = std::thread::spawn(move || {
        let mut lines = BufReader::new(stdout).lines();
        while let Some(line) = lines.next() {
            line_tx.send(line.expect("read app-server response")).ok();
        }
    });

    AppServerProcess {
        child,
        stdin,
        line_rx,
        reader,
    }
}

fn read_response(line_rx: &mpsc::Receiver<String>) -> Value {
    let line = line_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("timely app-server response");
    serde_json::from_str(&line).expect("response JSON")
}
