use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(i64),
    String(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub id: RequestId,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub id: RequestId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: RpcErrorCode,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retryable: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RpcErrorCode {
    InvalidRequest,
    ParseError,
    NotInitialized,
    AlreadyInitialized,
    MethodNotFound,
    Overloaded,
    BackendUnsupported,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeResult {
    pub server_name: String,
    pub protocol_version: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountListResult {
    pub accounts: Vec<Account>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderListParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderListResult {
    pub folders: Vec<Folder>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Folder {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub desc: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageListParams {
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default = "default_message_list_page")]
    pub page: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_size: Option<u32>,
}

fn default_message_list_page() -> u32 {
    1
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageListResult {
    pub envelopes: Vec<MessageEnvelope>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageGetParams {
    pub id: String,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageGetResult {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub html: Option<String>,
    #[serde(rename = "has_attachment")]
    pub has_attachment: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageModifyParams {
    pub id: String,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub add_flags: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub remove_flags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub move_to: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageModifyResult {
    pub id: String,
    pub folder: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSendParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSendResult {
    pub sent: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentDownloadParams {
    pub message_id: String,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    pub downloads_dir: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentDownloadResult {
    pub attachments: Vec<DownloadedAttachment>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadedAttachment {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageEnvelope {
    pub id: String,
    pub flags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<MessageAddress>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<MessageAddress>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    #[serde(rename = "has_attachment")]
    pub has_attachment: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageAddress {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub addr: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountHealthParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountHealthResult {
    pub account: Account,
    pub status: AccountHealthStatus,
    pub issues: Vec<AccountHealthIssue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountHealthStatus {
    Ok,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountHealthIssue {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backend: Option<String>,
    #[serde(rename = "default")]
    pub is_default: bool,
    #[serde(rename = "emailAddress", skip_serializing_if = "Option::is_none")]
    pub email_address: Option<String>,
    #[serde(rename = "displayName", skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
}

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("invalid request JSON: {0}")]
    Decode(#[from] serde_json::Error),
}

impl Response {
    pub fn result(id: RequestId, result: impl Serialize) -> Result<Self, serde_json::Error> {
        Ok(Self {
            id,
            result: Some(serde_json::to_value(result)?),
            error: None,
        })
    }

    pub fn error(id: RequestId, code: RpcErrorCode, message: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError {
                code,
                message: message.into(),
                retryable: None,
            }),
        }
    }

    pub fn retryable_error(id: RequestId, code: RpcErrorCode, message: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError {
                code,
                message: message.into(),
                retryable: Some(true),
            }),
        }
    }
}

pub fn decode_request(line: &str) -> Result<Request, ProtocolError> {
    Ok(serde_json::from_str(line)?)
}

pub fn encode_response(response: &Response) -> Result<String, serde_json::Error> {
    let mut line = serde_json::to_string(response)?;
    line.push('\n');
    Ok(line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn decodes_request_with_string_id() {
        let request = decode_request(r#"{"id":"abc","method":"initialize","params":{}}"#).unwrap();

        assert_eq!(request.id, RequestId::String("abc".to_owned()));
        assert_eq!(request.method, "initialize");
    }

    #[test]
    fn encodes_result_response_as_single_line() {
        let response = Response::result(
            RequestId::Number(1),
            InitializeResult {
                server_name: "mailia-mail".to_owned(),
                protocol_version: 1,
            },
        )
        .unwrap();

        let line = encode_response(&response).unwrap();

        assert!(line.ends_with('\n'));
        assert!(!line[..line.len() - 1].contains('\n'));
        assert!(line.contains(r#""serverName":"mailia-mail""#));
    }

    #[test]
    fn encodes_message_send_params() {
        let params = MessageSendParams {
            account: Some("work".to_owned()),
            raw: "From: sender@example.com\nTo: recipient@example.net\n\nHello".to_owned(),
        };

        let json = serde_json::to_string(&params).unwrap();

        assert!(json.contains(r#""account":"work""#));
        assert!(
            json.contains(
                r#""raw":"From: sender@example.com\nTo: recipient@example.net\n\nHello""#
            )
        );
    }

    #[test]
    fn encodes_initial_rpc_params_with_swift_client_field_names() {
        assert_eq!(
            serde_json::to_value(FolderListParams {
                account: Some("work".to_owned()),
            })
            .unwrap(),
            json!({ "account": "work" })
        );

        assert_eq!(
            serde_json::to_value(MessageListParams {
                folder: "INBOX".to_owned(),
                account: Some("work".to_owned()),
                query: Some("after 2026-05-30 order by date desc".to_owned()),
                page: 2,
                page_size: Some(50),
            })
            .unwrap(),
            json!({
                "folder": "INBOX",
                "account": "work",
                "query": "after 2026-05-30 order by date desc",
                "page": 2,
                "pageSize": 50
            })
        );

        assert_eq!(
            serde_json::to_value(MessageGetParams {
                id: "body:2,S".to_owned(),
                folder: "INBOX".to_owned(),
                account: Some("work".to_owned()),
            })
            .unwrap(),
            json!({
                "id": "body:2,S",
                "folder": "INBOX",
                "account": "work"
            })
        );

        assert_eq!(
            serde_json::to_value(MessageModifyParams {
                id: "body".to_owned(),
                folder: "INBOX".to_owned(),
                account: Some("work".to_owned()),
                add_flags: vec!["seen".to_owned()],
                remove_flags: vec!["flagged".to_owned()],
                move_to: Some("Archive".to_owned()),
            })
            .unwrap(),
            json!({
                "id": "body",
                "folder": "INBOX",
                "account": "work",
                "addFlags": ["seen"],
                "removeFlags": ["flagged"],
                "moveTo": "Archive"
            })
        );

        assert_eq!(
            serde_json::to_value(AttachmentDownloadParams {
                message_id: "body".to_owned(),
                folder: "INBOX".to_owned(),
                account: Some("work".to_owned()),
                downloads_dir: "/tmp/mailia-downloads".to_owned(),
            })
            .unwrap(),
            json!({
                "messageId": "body",
                "folder": "INBOX",
                "account": "work",
                "downloadsDir": "/tmp/mailia-downloads"
            })
        );
    }

    #[test]
    fn decodes_message_list_default_page_from_swift_client_params() {
        let params: MessageListParams = serde_json::from_value(json!({
            "folder": "INBOX",
            "account": "work"
        }))
        .unwrap();

        assert_eq!(params.folder, "INBOX");
        assert_eq!(params.account.as_deref(), Some("work"));
        assert_eq!(params.page, 1);
        assert_eq!(params.page_size, None);
    }

    #[test]
    fn encodes_initial_rpc_results_with_swift_client_field_names() {
        assert_eq!(
            serde_json::to_value(AccountListResult {
                accounts: vec![Account {
                    name: "work".to_owned(),
                    backend: Some("IMAP, SMTP".to_owned()),
                    is_default: true,
                    email_address: Some("work@example.com".to_owned()),
                    display_name: Some("Work".to_owned()),
                }],
            })
            .unwrap(),
            json!({
                "accounts": [{
                    "name": "work",
                    "backend": "IMAP, SMTP",
                    "default": true,
                    "emailAddress": "work@example.com",
                    "displayName": "Work"
                }]
            })
        );

        assert_eq!(
            serde_json::to_value(MessageListResult {
                envelopes: vec![MessageEnvelope {
                    id: "body:2,S".to_owned(),
                    flags: vec!["seen".to_owned()],
                    subject: Some("Body".to_owned()),
                    from: Some(MessageAddress {
                        name: Some("Sender".to_owned()),
                        addr: "sender@example.com".to_owned(),
                    }),
                    to: Some(MessageAddress {
                        name: Some("Recipient".to_owned()),
                        addr: "recipient@example.net".to_owned(),
                    }),
                    date: Some("2026-05-30 06:10+00:00".to_owned()),
                    has_attachment: true,
                }],
            })
            .unwrap(),
            json!({
                "envelopes": [{
                    "id": "body:2,S",
                    "flags": ["seen"],
                    "subject": "Body",
                    "from": {
                        "name": "Sender",
                        "addr": "sender@example.com"
                    },
                    "to": {
                        "name": "Recipient",
                        "addr": "recipient@example.net"
                    },
                    "date": "2026-05-30 06:10+00:00",
                    "has_attachment": true
                }]
            })
        );

        assert_eq!(
            serde_json::to_value(MessageGetResult {
                id: "body:2,S".to_owned(),
                text: Some("Plain body".to_owned()),
                html: Some("<p>HTML body</p>".to_owned()),
                has_attachment: false,
            })
            .unwrap(),
            json!({
                "id": "body:2,S",
                "text": "Plain body",
                "html": "<p>HTML body</p>",
                "has_attachment": false
            })
        );

        assert_eq!(
            serde_json::to_value(AttachmentDownloadResult {
                attachments: vec![DownloadedAttachment {
                    id: "1".to_owned(),
                    filename: Some("report.txt".to_owned()),
                    path: "/tmp/report.txt".to_owned(),
                    size: 11,
                }],
            })
            .unwrap(),
            json!({
                "attachments": [{
                    "id": "1",
                    "filename": "report.txt",
                    "path": "/tmp/report.txt",
                    "size": 11
                }]
            })
        );
    }

    #[test]
    fn encodes_retryable_rpc_error_for_swift_client() {
        let response = Response::retryable_error(
            RequestId::Number(7),
            RpcErrorCode::Overloaded,
            "request queue is saturated",
        );

        assert_eq!(
            serde_json::to_value(response).unwrap(),
            json!({
                "id": 7,
                "error": {
                    "code": "overloaded",
                    "message": "request queue is saturated",
                    "retryable": true
                }
            })
        );
    }
}
