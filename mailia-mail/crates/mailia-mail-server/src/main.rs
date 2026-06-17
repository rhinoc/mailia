use std::{
    env,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use mailia_mail_core::{PROTOCOL_VERSION, SERVER_NAME};
use mailia_mail_himalaya::{
    AccountHealth, AccountSummary, AttachmentDownloadCommand, DownloadedAttachmentSummary,
    FolderSummary, HimalayaConfigError, HimalayaConfigLoader, MessageAddressSummary,
    MessageBodySummary, MessageEnvelopeSummary, MessageGetQuery, MessageListQuery,
    MessageModifyCommand, MessageModifySummary, MessageSendCommand, MessageSendSummary,
};
use mailia_mail_protocol::{
    Account, AccountHealthIssue, AccountHealthParams, AccountHealthResult, AccountHealthStatus,
    AccountListResult, AttachmentDownloadParams, AttachmentDownloadResult, DownloadedAttachment,
    Folder, FolderListParams, FolderListResult, InitializeResult, MessageAddress, MessageEnvelope,
    MessageGetParams, MessageGetResult, MessageListParams, MessageListResult, MessageModifyParams,
    MessageModifyResult, MessageSendParams, MessageSendResult, Request, RequestId, Response,
    RpcErrorCode, decode_request, encode_response,
};
use serde::de::DeserializeOwned;
use serde_json::json;
use std::path::{Path, PathBuf};
use tokio::{
    io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{Semaphore, mpsc},
};

const MAX_IN_FLIGHT_REQUESTS: usize = 64;
const DEFAULT_BACKEND_TIMEOUT_MS: u64 = 25_000;

struct AppServerState {
    initialized: AtomicBool,
    shutdown: AtomicBool,
    config_loader: HimalayaConfigLoader,
    config_load_count: Arc<AtomicU64>,
    auth_refresh_count: Arc<AtomicU64>,
}

impl AppServerState {
    fn new() -> Self {
        let config_load_count = Arc::new(AtomicU64::new(0));
        let observed_config_load_count = config_load_count.clone();
        let auth_refresh_count = Arc::new(AtomicU64::new(0));
        let observed_auth_refresh_count = auth_refresh_count.clone();
        Self {
            initialized: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            config_loader: HimalayaConfigLoader::cached_with_observers(
                Arc::new(move || {
                    observed_config_load_count.fetch_add(1, Ordering::SeqCst);
                }),
                Arc::new(move || {
                    observed_auth_refresh_count.fetch_add(1, Ordering::SeqCst);
                }),
            ),
            config_load_count,
            auth_refresh_count,
        }
    }

    fn config_loader(&self) -> &HimalayaConfigLoader {
        &self.config_loader
    }

    fn is_shutdown(&self) -> bool {
        self.shutdown.load(Ordering::SeqCst)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    match args.as_slice() {
        [command, listen_flag, listen] if command == "app-server" && listen_flag == "--listen" => {
            if listen != "stdio://" {
                bail!("unsupported listener `{listen}`");
            }
            run_stdio().await
        }
        _ => {
            eprintln!("usage: mailia-mail app-server --listen stdio://");
            std::process::exit(64);
        }
    }
}

async fn run_stdio() -> Result<()> {
    eprintln!("{SERVER_NAME}: listening on stdio");

    let state = Arc::new(AppServerState::new());
    let max_in_flight = max_in_flight_requests();
    let response_buffer = max_in_flight.max(1);
    let semaphore = Arc::new(Semaphore::new(max_in_flight));
    let (tx, mut rx) = mpsc::channel::<Response>(response_buffer);

    let writer = tokio::spawn(async move {
        let mut stdout = io::stdout();
        while let Some(response) = rx.recv().await {
            let line = encode_response(&response).context("encode JSON-RPC response")?;
            stdout
                .write_all(line.as_bytes())
                .await
                .context("write JSON-RPC response")?;
            stdout.flush().await.context("flush JSON-RPC response")?;
        }
        Result::<()>::Ok(())
    });

    let stdin = io::stdin();
    let mut lines = BufReader::new(stdin).lines();

    while let Some(line) = lines.next_line().await.context("read JSON-RPC request")? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let request = match decode_request(line) {
            Ok(request) => request,
            Err(err) => {
                eprintln!("{SERVER_NAME}: rejected invalid request: {err}");
                tx.send(parse_error_response(err)).await.ok();
                continue;
            }
        };

        let id = request.id.clone();

        if request.method == "initialize" || request.method == "shutdown" {
            let response = handle_request_and_log(request, state.clone());
            tx.send(response).await.ok();
            if state.is_shutdown() {
                break;
            }
            continue;
        }

        let permit = match semaphore.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                tx.send(Response::retryable_error(
                    id,
                    RpcErrorCode::Overloaded,
                    "request queue is saturated",
                ))
                .await
                .ok();
                continue;
            }
        };

        let tx = tx.clone();
        let state_for_task = state.clone();

        tokio::spawn(async move {
            let method = request.method.clone();
            let id = request.id.clone();
            let started_at = Instant::now();
            let timeout = backend_timeout();
            let state_for_metric = state_for_task.clone();
            let (response_tx, response_rx) = tokio::sync::oneshot::channel();
            std::thread::spawn(move || {
                let response = handle_request(request, state_for_task).with_id_fallback();
                response_tx.send(response).ok();
            });
            let response = match tokio::time::timeout(timeout, response_rx).await {
                Ok(Ok(response)) => response,
                Ok(Err(_closed)) => {
                    retryable_backend_error(id, "request worker exited without a response")
                }
                Err(_) => retryable_backend_error(
                    id,
                    format!("request timed out after {} ms", timeout.as_millis()),
                ),
            };
            log_request_metric(
                &method,
                &response,
                started_at.elapsed(),
                state_for_metric.as_ref(),
            );
            let _permit = permit;
            tx.send(response).await.ok();
        });

        if state.is_shutdown() {
            break;
        }
    }

    drop(tx);
    writer.await.context("join stdio writer")??;
    eprintln!("{SERVER_NAME}: stopped");
    Ok(())
}

fn handle_request_and_log(request: Request, state: Arc<AppServerState>) -> Response {
    let method = request.method.clone();
    let started_at = Instant::now();
    let response = handle_request(request, state.clone()).with_id_fallback();
    log_request_metric(&method, &response, started_at.elapsed(), state.as_ref());
    response
}

fn parse_error_response(error: mailia_mail_protocol::ProtocolError) -> Response {
    Response::error(
        RequestId::String("parse_error".to_owned()),
        RpcErrorCode::ParseError,
        error.to_string(),
    )
}

fn handle_request(request: Request, state: Arc<AppServerState>) -> Response {
    let response = match request.method.as_str() {
        "initialize" => initialize(request.id, state.as_ref()),
        "server/noop" => require_initialized(request.id, &state.initialized, |id| {
            Response::result(id, json!({ "ok": true }))
        }),
        "account/list" => require_initialized(request.id, &state.initialized, |id| {
            account_list(id, state.as_ref())
        }),
        "account/health" => require_initialized(request.id, &state.initialized, |id| {
            account_health(id, request.params, state.as_ref())
        }),
        "folder/list" => require_initialized(request.id, &state.initialized, |id| {
            folder_list(id, request.params, state.as_ref())
        }),
        "message/list" => require_initialized(request.id, &state.initialized, |id| {
            message_list(id, request.params, state.as_ref())
        }),
        "message/get" => require_initialized(request.id, &state.initialized, |id| {
            message_get(id, request.params, state.as_ref())
        }),
        "message/modify" => require_initialized(request.id, &state.initialized, |id| {
            message_modify(id, request.params, state.as_ref())
        }),
        "message/send" => require_initialized(request.id, &state.initialized, |id| {
            message_send(id, request.params, state.as_ref())
        }),
        "attachment/download" => require_initialized(request.id, &state.initialized, |id| {
            attachment_download(id, request.params, state.as_ref())
        }),
        "shutdown" => require_initialized(request.id, &state.initialized, |id| {
            state.shutdown.store(true, Ordering::SeqCst);
            Response::result(id, json!({ "ok": true }))
        }),
        _ => Response::error(
            request.id,
            RpcErrorCode::MethodNotFound,
            format!("unknown method `{}`", request.method),
        ),
    }
    .with_id_fallback();
    response
}

fn backend_timeout() -> Duration {
    env::var("MAILIA_APP_SERVER_BACKEND_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .map(Duration::from_millis)
        .unwrap_or_else(|| Duration::from_millis(DEFAULT_BACKEND_TIMEOUT_MS))
}

fn max_in_flight_requests() -> usize {
    env::var("MAILIA_APP_SERVER_MAX_IN_FLIGHT_REQUESTS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(MAX_IN_FLIGHT_REQUESTS)
}

fn account_health(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: AccountHealthParams = match decode_params(&id, "account/health", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    match state
        .config_loader()
        .account_health(params.account.as_deref())
    {
        Ok(health) => Response::result(id, account_health_from_config(health)),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn account_list(id: RequestId, state: &AppServerState) -> Result<Response, serde_json::Error> {
    match state.config_loader().load_accounts() {
        Ok(accounts) => Response::result(
            id,
            AccountListResult {
                accounts: accounts.into_iter().map(account_from_summary).collect(),
            },
        ),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn folder_list(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: FolderListParams = match decode_params(&id, "folder/list", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    match state.config_loader().folder_list(params.account.as_deref()) {
        Ok(folders) => Response::result(
            id,
            FolderListResult {
                folders: folders.into_iter().map(folder_from_summary).collect(),
            },
        ),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn message_list(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: MessageListParams = match decode_params(&id, "message/list", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    let query = MessageListQuery {
        account: params.account,
        folder: params.folder,
        query: params.query,
        page: params.page,
        page_size: params.page_size,
    };
    match state.config_loader().message_list(query) {
        Ok(envelopes) => Response::result(
            id,
            MessageListResult {
                envelopes: envelopes.into_iter().map(message_from_summary).collect(),
            },
        ),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn message_get(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: MessageGetParams = match decode_params(&id, "message/get", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    let query = MessageGetQuery {
        account: params.account,
        folder: params.folder,
        id: params.id,
    };
    match state.config_loader().message_get(query) {
        Ok(message) => Response::result(id, message_get_from_summary(message)),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn message_modify(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: MessageModifyParams = match decode_params(&id, "message/modify", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    let command = MessageModifyCommand {
        account: params.account,
        folder: params.folder,
        id: params.id,
        add_flags: params.add_flags,
        remove_flags: params.remove_flags,
        move_to: params.move_to,
    };
    match state.config_loader().message_modify(command) {
        Ok(summary) => Response::result(id, message_modify_from_summary(summary)),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn attachment_download(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: AttachmentDownloadParams = match decode_params(&id, "attachment/download", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    let command = AttachmentDownloadCommand {
        account: params.account,
        folder: params.folder,
        message_id: params.message_id,
        downloads_dir: PathBuf::from(params.downloads_dir),
    };
    match state.config_loader().attachment_download(command) {
        Ok(attachments) => Response::result(
            id,
            AttachmentDownloadResult {
                attachments: attachments
                    .into_iter()
                    .map(downloaded_attachment_from_summary)
                    .collect(),
            },
        ),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn message_send(
    id: RequestId,
    params: serde_json::Value,
    state: &AppServerState,
) -> Result<Response, serde_json::Error> {
    let params: MessageSendParams = match decode_params(&id, "message/send", params) {
        Ok(params) => params,
        Err(response) => return Ok(response),
    };
    let command = MessageSendCommand {
        account: params.account,
        raw: params.raw.into_bytes(),
    };
    match state.config_loader().message_send(command) {
        Ok(summary) => Response::result(id, message_send_from_summary(summary)),
        Err(error) => Ok(config_error_response(id, error)),
    }
}

fn decode_params<T: DeserializeOwned>(
    id: &RequestId,
    method: &str,
    params: serde_json::Value,
) -> Result<T, Response> {
    serde_json::from_value(params).map_err(|err| {
        Response::error(
            id.clone(),
            RpcErrorCode::InvalidRequest,
            format!("invalid params for `{method}`: {err}"),
        )
    })
}

fn config_error_response(id: RequestId, error: HimalayaConfigError) -> Response {
    match error {
        HimalayaConfigError::ConfigNotFound => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            "Himalaya configuration file was not found",
        ),
        HimalayaConfigError::ReadConfig { path, source } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!(
                "Unable to read Himalaya configuration file `{}`: {source}",
                sanitized_config_path(&path)
            ),
        ),
        HimalayaConfigError::ParseConfig { path, source } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!(
                "Unable to parse Himalaya configuration file `{}`: {source}",
                sanitized_config_path(&path)
            ),
        ),
        HimalayaConfigError::AccountNotFound(account) => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Account `{account}` was not found in Himalaya configuration"),
        ),
        HimalayaConfigError::DefaultAccountNotFound => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            "No default account was found in Himalaya configuration",
        ),
        HimalayaConfigError::FolderBackendUnsupported { account, backend } => Response::error(
            id,
            RpcErrorCode::BackendUnsupported,
            format!(
                "Folder listing is not implemented for account `{account}` backend `{backend}`"
            ),
        ),
        HimalayaConfigError::MessageBackendUnsupported { account, backend } => Response::error(
            id,
            RpcErrorCode::BackendUnsupported,
            format!(
                "Message listing is not implemented for account `{account}` backend `{backend}`"
            ),
        ),
        HimalayaConfigError::MessageQueryUnsupported { account, query } => Response::error(
            id,
            RpcErrorCode::BackendUnsupported,
            format!("Message listing query `{query}` is not supported for account `{account}`"),
        ),
        HimalayaConfigError::InvalidFolder { account, folder } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Invalid folder `{folder}` for account `{account}`"),
        ),
        HimalayaConfigError::MessageNotFound {
            account,
            folder,
            id: message_id,
        } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!(
                "Message `{message_id}` was not found in folder `{folder}` for account `{account}`"
            ),
        ),
        HimalayaConfigError::ParseMessage {
            account,
            folder,
            id: message_id,
        } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!(
                "Unable to parse message `{message_id}` in folder `{folder}` for account `{account}`"
            ),
        ),
        HimalayaConfigError::MessageFlagUnsupported { account, flag } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Message flag `{flag}` is not supported for account `{account}`"),
        ),
        HimalayaConfigError::AttachmentNotFound {
            account,
            folder,
            id: message_id,
        } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!(
                "Message `{message_id}` has no attachments in folder `{folder}` for account `{account}`"
            ),
        ),
        HimalayaConfigError::SmtpBackendUnsupported { account, backend } => Response::error(
            id,
            RpcErrorCode::BackendUnsupported,
            format!("SMTP send is not implemented for account `{account}` backend `{backend}`"),
        ),
        HimalayaConfigError::ParseSmtpConfig { account, source } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Unable to parse SMTP config for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ParseSmtpServerUrl {
            account,
            server,
            source,
        } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Unable to parse SMTP server URL `{server}` for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ResolveSmtpSecret { account, source } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Unable to resolve SMTP secret for account `{account}`: {source}"),
        ),
        HimalayaConfigError::InvalidOutgoingMessage { account, message } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Invalid outgoing message for account `{account}`: {message}"),
        ),
        HimalayaConfigError::SmtpSend { account, source } => retryable_backend_error(
            id,
            format!("SMTP send failed for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ParseImapConfig { account, source } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Unable to parse IMAP config for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ParseImapServerUrl {
            account,
            server,
            source,
        } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Unable to parse IMAP server URL `{server}` for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ResolveImapSecret { account, source } => Response::error(
            id,
            RpcErrorCode::InvalidRequest,
            format!("Unable to resolve IMAP secret for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ImapConnect { account, source } => retryable_backend_error(
            id,
            format!("IMAP connection failed for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ImapFolderList { account, source } => retryable_backend_error(
            id,
            format!("IMAP folder listing failed for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ImapMessageList { account, source } => retryable_backend_error(
            id,
            format!("IMAP message listing failed for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ImapMessageGet { account, source } => retryable_backend_error(
            id,
            format!("IMAP message get failed for account `{account}`: {source}"),
        ),
        HimalayaConfigError::ImapMessageModify { account, source } => retryable_backend_error(
            id,
            format!("IMAP message modify failed for account `{account}`: {source}"),
        ),
    }
}

fn retryable_backend_error(id: RequestId, message: impl Into<String>) -> Response {
    Response::retryable_error(id, RpcErrorCode::Internal, message)
}

fn sanitized_config_path(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("config.toml")
        .to_owned()
}

fn initialize(id: RequestId, state: &AppServerState) -> Response {
    if state
        .initialized
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Response::error(
            id,
            RpcErrorCode::AlreadyInitialized,
            "connection is already initialized",
        );
    }

    Response::result(
        id,
        InitializeResult {
            server_name: SERVER_NAME.to_owned(),
            protocol_version: PROTOCOL_VERSION,
        },
    )
    .unwrap_or_else(|err| {
        Response::error(
            RequestId::Number(0),
            RpcErrorCode::Internal,
            format!("failed to encode initialize result: {err}"),
        )
    })
}

fn log_request_metric(
    method: &str,
    response: &Response,
    duration: Duration,
    state: &AppServerState,
) {
    let status = if response.error.is_some() {
        "error"
    } else {
        "ok"
    };
    eprintln!(
        "{SERVER_NAME}: request request_id={} method={method} status={status} duration_ms={} config_load_count={} auth_refresh_count={}",
        request_id_metric_value(&response.id),
        duration.as_millis(),
        state.config_load_count.load(Ordering::SeqCst),
        state.auth_refresh_count.load(Ordering::SeqCst)
    );
}

fn request_id_metric_value(id: &RequestId) -> String {
    match id {
        RequestId::Number(value) => value.to_string(),
        RequestId::String(value) => value
            .chars()
            .map(|character| {
                if character.is_whitespace() || character == '=' {
                    '_'
                } else {
                    character
                }
            })
            .collect(),
    }
}

fn account_from_summary(account: AccountSummary) -> Account {
    Account {
        name: account.name,
        backend: account.backend,
        is_default: account.is_default,
        email_address: account.email_address,
        display_name: account.display_name,
    }
}

fn folder_from_summary(folder: FolderSummary) -> Folder {
    Folder {
        name: folder.name,
        desc: folder.desc,
    }
}

fn message_from_summary(message: MessageEnvelopeSummary) -> MessageEnvelope {
    MessageEnvelope {
        id: message.id,
        flags: message.flags,
        subject: message.subject,
        from: message.from.map(address_from_summary),
        to: message.to.map(address_from_summary),
        date: message.date,
        has_attachment: message.has_attachment,
    }
}

fn message_get_from_summary(message: MessageBodySummary) -> MessageGetResult {
    MessageGetResult {
        id: message.id,
        text: message.text,
        html: message.html,
        has_attachment: message.has_attachment,
    }
}

fn message_modify_from_summary(message: MessageModifySummary) -> MessageModifyResult {
    MessageModifyResult {
        id: message.id,
        folder: message.folder,
    }
}

fn downloaded_attachment_from_summary(
    attachment: DownloadedAttachmentSummary,
) -> DownloadedAttachment {
    DownloadedAttachment {
        id: attachment.id,
        filename: attachment.filename,
        path: attachment.path.display().to_string(),
        size: attachment.size,
    }
}

fn message_send_from_summary(summary: MessageSendSummary) -> MessageSendResult {
    MessageSendResult { sent: summary.sent }
}

fn address_from_summary(address: MessageAddressSummary) -> MessageAddress {
    MessageAddress {
        name: address.name,
        addr: address.addr,
    }
}

fn account_health_from_config(health: AccountHealth) -> AccountHealthResult {
    AccountHealthResult {
        account: account_from_summary(health.account),
        status: match health.status {
            mailia_mail_himalaya::AccountHealthStatus::Ok => AccountHealthStatus::Ok,
            mailia_mail_himalaya::AccountHealthStatus::Warning => AccountHealthStatus::Warning,
        },
        issues: health
            .issues
            .into_iter()
            .map(|issue| AccountHealthIssue {
                code: issue.code.to_owned(),
                message: issue.message,
            })
            .collect(),
    }
}

fn require_initialized(
    id: RequestId,
    initialized: &AtomicBool,
    response: impl FnOnce(RequestId) -> Result<Response, serde_json::Error>,
) -> Response {
    if !initialized.load(Ordering::SeqCst) {
        return Response::error(
            id,
            RpcErrorCode::NotInitialized,
            "`initialize` must be the first request",
        );
    }

    response(id).unwrap_or_else(|err| {
        Response::error(
            RequestId::Number(0),
            RpcErrorCode::Internal,
            format!("failed to encode response: {err}"),
        )
    })
}

trait ResponseIdFallback {
    fn with_id_fallback(self) -> Response;
}

impl ResponseIdFallback for Response {
    fn with_id_fallback(mut self) -> Response {
        if matches!(self.id, RequestId::Number(0)) {
            self.id = RequestId::String("internal".to_owned());
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_must_be_first_request() {
        let state = Arc::new(AppServerState::new());

        let response = handle_request(
            Request {
                id: RequestId::Number(7),
                method: "server/noop".to_owned(),
                params: json!({}),
            },
            state.clone(),
        );

        assert_eq!(response.id, RequestId::Number(7));
        assert_eq!(response.error.unwrap().code, RpcErrorCode::NotInitialized);
        assert_eq!(state.config_load_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn initialize_then_noop_succeeds() {
        let state = Arc::new(AppServerState::new());

        let init = handle_request(
            Request {
                id: RequestId::Number(1),
                method: "initialize".to_owned(),
                params: json!({}),
            },
            state.clone(),
        );
        assert!(init.error.is_none());

        let noop = handle_request(
            Request {
                id: RequestId::String("noop".to_owned()),
                method: "server/noop".to_owned(),
                params: json!({}),
            },
            state.clone(),
        );

        assert_eq!(noop.id, RequestId::String("noop".to_owned()));
        assert_eq!(noop.result.unwrap(), json!({ "ok": true }));
        assert_eq!(state.config_load_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn invalid_method_params_return_invalid_request_with_original_id() {
        let state = Arc::new(AppServerState::new());
        state.initialized.store(true, Ordering::SeqCst);

        let response = handle_request(
            Request {
                id: RequestId::Number(42),
                method: "message/list".to_owned(),
                params: json!({
                    "account": "work",
                    "page": 1
                }),
            },
            state.clone(),
        );

        assert_eq!(response.id, RequestId::Number(42));
        let error = response.error.unwrap();
        assert_eq!(error.code, RpcErrorCode::InvalidRequest);
        assert!(error.message.contains("invalid params for `message/list`"));
        assert!(error.message.contains("missing field `folder`"));
        assert_eq!(state.config_load_count.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn config_rpc_error_does_not_expose_full_local_path() {
        let response = config_error_response(
            RequestId::Number(10),
            HimalayaConfigError::ReadConfig {
                path: "/Users/example/Library/Application Support/himalaya/config.toml".to_owned(),
                source: std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied"),
            },
        );

        assert_eq!(response.id, RequestId::Number(10));
        let error = response.error.unwrap();
        assert_eq!(error.code, RpcErrorCode::InvalidRequest);
        assert!(error.message.contains("config.toml"));
        assert!(error.message.contains("denied"));
        assert!(!error.message.contains("/Users/example"));
        assert!(!error.message.contains("Application Support"));
    }

    #[test]
    fn backend_timeout_error_is_retryable() {
        let response = retryable_backend_error(
            RequestId::String("slow".to_owned()),
            "request timed out after 25 ms",
        );

        assert_eq!(response.id, RequestId::String("slow".to_owned()));
        let error = response.error.unwrap();
        assert_eq!(error.code, RpcErrorCode::Internal);
        assert_eq!(error.retryable, Some(true));
        assert_eq!(error.message, "request timed out after 25 ms");
    }

    #[test]
    fn request_metric_id_value_is_grep_friendly() {
        assert_eq!(request_id_metric_value(&RequestId::Number(42)), "42");
        assert_eq!(
            request_id_metric_value(&RequestId::String("slow request=1".to_owned())),
            "slow_request_1"
        );
    }

    #[test]
    fn concurrent_requests_keep_their_response_ids() {
        let state = Arc::new(AppServerState::new());
        state.initialized.store(true, Ordering::SeqCst);

        let first_state = state.clone();
        let first = std::thread::spawn(move || {
            handle_request(
                Request {
                    id: RequestId::Number(41),
                    method: "server/noop".to_owned(),
                    params: json!({}),
                },
                first_state,
            )
        });
        let second = std::thread::spawn(move || {
            handle_request(
                Request {
                    id: RequestId::String("second".to_owned()),
                    method: "server/noop".to_owned(),
                    params: json!({}),
                },
                state,
            )
        });

        assert_eq!(first.join().unwrap().id, RequestId::Number(41));
        assert_eq!(
            second.join().unwrap().id,
            RequestId::String("second".to_owned())
        );
    }
}
