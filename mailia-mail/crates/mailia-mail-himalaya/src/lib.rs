use std::{
    borrow::Cow,
    collections::{BTreeMap, HashSet, btree_map::Entry},
    env, fmt, fs,
    net::Ipv4Addr,
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
};

use chrono::{FixedOffset, NaiveDate, TimeZone};
use io_imap::{
    client::{ImapClientStd, ImapClientStdError, default_alpn},
    types::{
        core::{AString, Vec1},
        datetime::NaiveDate as ImapNaiveDate,
        fetch::{MacroOrMessageDataItemNames, MessageDataItem, MessageDataItemName},
        flag::{Flag, FlagFetch, FlagNameAttribute, StoreType},
        mailbox::{ListMailbox, Mailbox},
        search::SearchKey,
        sequence::SequenceSet,
    },
};
use io_smtp::{
    client::{SmtpClientStd, SmtpClientStdError, default_alpn as default_smtp_alpn},
    rfc5321::types::{
        domain::Domain, ehlo_domain::EhloDomain, forward_path::ForwardPath, local_part::LocalPart,
        mailbox::Mailbox as SmtpMailbox, reverse_path::ReversePath,
    },
};
use mail_parser::{
    Addr, Address as ParsedAddress, DateTime as ParsedDateTime, HeaderName, HeaderValue,
    MessageParser, MimeHeaders,
};
use pimalaya_config::secret::{Secret, SecretError};
use pimalaya_stream::{
    sasl::{
        Sasl, SaslAnonymous, SaslLogin, SaslOauthbearer, SaslPlain, SaslScramSha256, SaslXoauth2,
    },
    tls::{Rustls, Tls},
};
use secrecy::SecretString;
use serde::Deserialize;
use thiserror::Error;
use url::{ParseError, Url};

pub const PROJECT_NAME: &str = "himalaya";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountSummary {
    pub name: String,
    pub backend: Option<String>,
    pub is_default: bool,
    pub email_address: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountHealth {
    pub account: AccountSummary,
    pub status: AccountHealthStatus,
    pub issues: Vec<AccountHealthIssue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountHealthStatus {
    Ok,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountHealthIssue {
    pub code: &'static str,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderSummary {
    pub name: String,
    pub desc: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageListQuery {
    pub account: Option<String>,
    pub folder: String,
    pub query: Option<String>,
    pub page: u32,
    pub page_size: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageGetQuery {
    pub account: Option<String>,
    pub folder: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageModifyCommand {
    pub account: Option<String>,
    pub folder: String,
    pub id: String,
    pub add_flags: Vec<String>,
    pub remove_flags: Vec<String>,
    pub move_to: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageModifySummary {
    pub id: String,
    pub folder: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentDownloadCommand {
    pub account: Option<String>,
    pub folder: String,
    pub message_id: String,
    pub downloads_dir: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSendCommand {
    pub account: Option<String>,
    pub raw: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSendSummary {
    pub sent: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadedAttachmentSummary {
    pub id: String,
    pub filename: Option<String>,
    pub path: PathBuf,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageEnvelopeSummary {
    pub id: String,
    pub flags: Vec<String>,
    pub subject: Option<String>,
    pub from: Option<MessageAddressSummary>,
    pub to: Option<MessageAddressSummary>,
    pub date: Option<String>,
    pub has_attachment: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageAddressSummary {
    pub name: Option<String>,
    pub addr: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageBodySummary {
    pub id: String,
    pub text: Option<String>,
    pub html: Option<String>,
    pub has_attachment: bool,
}

#[derive(Debug, Error)]
pub enum HimalayaConfigError {
    #[error("unable to find the Himalaya configuration file")]
    ConfigNotFound,
    #[error("unable to read Himalaya configuration file at {path}: {source}")]
    ReadConfig {
        path: String,
        source: std::io::Error,
    },
    #[error("unable to parse Himalaya configuration file at {path}: {source}")]
    ParseConfig {
        path: String,
        source: toml::de::Error,
    },
    #[error("account `{0}` was not found in Himalaya configuration")]
    AccountNotFound(String),
    #[error("no default account was found in Himalaya configuration")]
    DefaultAccountNotFound,
    #[error("folder listing is not implemented for account `{account}` backend `{backend}`")]
    FolderBackendUnsupported { account: String, backend: String },
    #[error("message listing is not implemented for account `{account}` backend `{backend}`")]
    MessageBackendUnsupported { account: String, backend: String },
    #[error("message listing query `{query}` is not supported for account `{account}`")]
    MessageQueryUnsupported { account: String, query: String },
    #[error("invalid folder `{folder}` for account `{account}`")]
    InvalidFolder { account: String, folder: String },
    #[error("message `{id}` was not found in folder `{folder}` for account `{account}`")]
    MessageNotFound {
        account: String,
        folder: String,
        id: String,
    },
    #[error("unable to parse message `{id}` in folder `{folder}` for account `{account}`")]
    ParseMessage {
        account: String,
        folder: String,
        id: String,
    },
    #[error("message flag `{flag}` is not supported for account `{account}`")]
    MessageFlagUnsupported { account: String, flag: String },
    #[error("message `{id}` has no attachments in folder `{folder}` for account `{account}`")]
    AttachmentNotFound {
        account: String,
        folder: String,
        id: String,
    },
    #[error("SMTP send is not implemented for account `{account}` backend `{backend}`")]
    SmtpBackendUnsupported { account: String, backend: String },
    #[error("unable to parse SMTP config for account `{account}`: {source}")]
    ParseSmtpConfig {
        account: String,
        source: toml::de::Error,
    },
    #[error("unable to parse SMTP server URL `{server}` for account `{account}`: {source}")]
    ParseSmtpServerUrl {
        account: String,
        server: String,
        source: ParseError,
    },
    #[error("unable to resolve SMTP secret for account `{account}`: {source}")]
    ResolveSmtpSecret {
        account: String,
        source: SecretError,
    },
    #[error("invalid outgoing message for account `{account}`: {message}")]
    InvalidOutgoingMessage { account: String, message: String },
    #[error("SMTP send failed for account `{account}`: {source}")]
    SmtpSend {
        account: String,
        source: SmtpClientStdError,
    },
    #[error("unable to parse IMAP config for account `{account}`: {source}")]
    ParseImapConfig {
        account: String,
        source: toml::de::Error,
    },
    #[error("unable to parse IMAP server URL `{server}` for account `{account}`: {source}")]
    ParseImapServerUrl {
        account: String,
        server: String,
        source: ParseError,
    },
    #[error("unable to resolve IMAP secret for account `{account}`: {source}")]
    ResolveImapSecret {
        account: String,
        source: SecretError,
    },
    #[error("IMAP connection failed for account `{account}`: {source}")]
    ImapConnect {
        account: String,
        source: ImapClientStdError,
    },
    #[error("IMAP folder listing failed for account `{account}`: {source}")]
    ImapFolderList {
        account: String,
        source: ImapClientStdError,
    },
    #[error("IMAP message listing failed for account `{account}`: {source}")]
    ImapMessageList {
        account: String,
        source: ImapClientStdError,
    },
    #[error("IMAP message get failed for account `{account}`: {source}")]
    ImapMessageGet {
        account: String,
        source: ImapClientStdError,
    },
    #[error("IMAP message modify failed for account `{account}`: {source}")]
    ImapMessageModify {
        account: String,
        source: ImapClientStdError,
    },
}

#[derive(Clone)]
pub struct HimalayaConfigLoader {
    config_paths: Option<Vec<PathBuf>>,
    cached_config: Option<Arc<Mutex<Option<Arc<ConfigDocument>>>>>,
    load_observer: Option<Arc<dyn Fn() + Send + Sync>>,
    auth_refresh_observer: Option<Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<ImapSessionPool>,
}

impl HimalayaConfigLoader {
    pub fn new() -> Self {
        Self {
            config_paths: None,
            cached_config: None,
            load_observer: None,
            auth_refresh_observer: None,
            imap_session_pool: None,
        }
    }

    pub fn with_config_paths(config_paths: Vec<PathBuf>) -> Self {
        Self {
            config_paths: Some(config_paths),
            cached_config: None,
            load_observer: None,
            auth_refresh_observer: None,
            imap_session_pool: None,
        }
    }

    pub fn cached_with_load_observer(load_observer: Arc<dyn Fn() + Send + Sync>) -> Self {
        Self {
            config_paths: None,
            cached_config: Some(Arc::new(Mutex::new(None))),
            load_observer: Some(load_observer),
            auth_refresh_observer: None,
            imap_session_pool: Some(ImapSessionPool::new()),
        }
    }

    pub fn cached_with_observers(
        load_observer: Arc<dyn Fn() + Send + Sync>,
        auth_refresh_observer: Arc<dyn Fn() + Send + Sync>,
    ) -> Self {
        Self {
            config_paths: None,
            cached_config: Some(Arc::new(Mutex::new(None))),
            load_observer: Some(load_observer),
            auth_refresh_observer: Some(auth_refresh_observer),
            imap_session_pool: Some(ImapSessionPool::new()),
        }
    }

    pub fn cached_with_config_paths_and_load_observer(
        config_paths: Vec<PathBuf>,
        load_observer: Arc<dyn Fn() + Send + Sync>,
    ) -> Self {
        Self {
            config_paths: Some(config_paths),
            cached_config: Some(Arc::new(Mutex::new(None))),
            load_observer: Some(load_observer),
            auth_refresh_observer: None,
            imap_session_pool: Some(ImapSessionPool::new()),
        }
    }

    pub fn load_accounts(&self) -> Result<Vec<AccountSummary>, HimalayaConfigError> {
        let config = self.load_config()?;
        Ok(config.accounts())
    }

    pub fn account_health(
        &self,
        account_name: Option<&str>,
    ) -> Result<AccountHealth, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(account_name)?;
        Ok(account_health(account, table))
    }

    pub fn folder_list(
        &self,
        account_name: Option<&str>,
    ) -> Result<Vec<FolderSummary>, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(account_name)?;

        if let Some(root) = maildir_root(table) {
            return list_maildir_folders(root);
        }
        if table.contains_key("imap") {
            return list_imap_folders(
                &account.name,
                table,
                self.auth_refresh_observer.as_ref(),
                self.imap_session_pool.as_ref(),
            );
        }

        Err(HimalayaConfigError::FolderBackendUnsupported {
            account: account.name,
            backend: account.backend.unwrap_or_else(|| "None".to_owned()),
        })
    }

    pub fn message_list(
        &self,
        query: MessageListQuery,
    ) -> Result<Vec<MessageEnvelopeSummary>, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(query.account.as_deref())?;

        if let Some(root) = maildir_root(table) {
            return list_maildir_messages(&account.name, root, query);
        }
        if table.contains_key("imap") {
            return list_imap_messages(
                &account.name,
                table,
                query,
                self.auth_refresh_observer.as_ref(),
                self.imap_session_pool.as_ref(),
            );
        }

        Err(HimalayaConfigError::MessageBackendUnsupported {
            account: account.name,
            backend: account.backend.unwrap_or_else(|| "None".to_owned()),
        })
    }

    pub fn message_get(
        &self,
        query: MessageGetQuery,
    ) -> Result<MessageBodySummary, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(query.account.as_deref())?;

        if let Some(root) = maildir_root(table) {
            return get_maildir_message(&account.name, root, query);
        }
        if table.contains_key("imap") {
            return get_imap_message(
                &account.name,
                table,
                query,
                self.auth_refresh_observer.as_ref(),
                self.imap_session_pool.as_ref(),
            );
        }

        Err(HimalayaConfigError::MessageBackendUnsupported {
            account: account.name,
            backend: account.backend.unwrap_or_else(|| "None".to_owned()),
        })
    }

    pub fn message_modify(
        &self,
        command: MessageModifyCommand,
    ) -> Result<MessageModifySummary, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(command.account.as_deref())?;

        if let Some(root) = maildir_root(table) {
            return modify_maildir_message(&account.name, root, command);
        }
        if table.contains_key("imap") {
            return modify_imap_message(
                &account.name,
                table,
                command,
                self.auth_refresh_observer.as_ref(),
                self.imap_session_pool.as_ref(),
            );
        }

        Err(HimalayaConfigError::MessageBackendUnsupported {
            account: account.name,
            backend: account.backend.unwrap_or_else(|| "None".to_owned()),
        })
    }

    pub fn attachment_download(
        &self,
        command: AttachmentDownloadCommand,
    ) -> Result<Vec<DownloadedAttachmentSummary>, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(command.account.as_deref())?;

        if let Some(root) = maildir_root(table) {
            return download_maildir_attachments(&account.name, root, command);
        }
        if table.contains_key("imap") {
            return download_imap_attachments(
                &account.name,
                table,
                command,
                self.auth_refresh_observer.as_ref(),
                self.imap_session_pool.as_ref(),
            );
        }

        Err(HimalayaConfigError::MessageBackendUnsupported {
            account: account.name,
            backend: account.backend.unwrap_or_else(|| "None".to_owned()),
        })
    }

    pub fn message_send(
        &self,
        command: MessageSendCommand,
    ) -> Result<MessageSendSummary, HimalayaConfigError> {
        let config = self.load_config()?;
        let (account, table) = config.select_account_table(command.account.as_deref())?;

        if table.contains_key("smtp") {
            return send_smtp_message(
                &account.name,
                table,
                command.raw,
                self.auth_refresh_observer.as_ref(),
            );
        }

        Err(HimalayaConfigError::SmtpBackendUnsupported {
            account: account.name,
            backend: account.backend.unwrap_or_else(|| "None".to_owned()),
        })
    }

    fn load_config(&self) -> Result<Arc<ConfigDocument>, HimalayaConfigError> {
        if let Some(cached_config) = &self.cached_config {
            let mut cached_config = cached_config
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(config) = cached_config.as_ref() {
                return Ok(config.clone());
            }

            let config = Arc::new(self.read_config()?);
            *cached_config = Some(config.clone());
            return Ok(config);
        }

        Ok(Arc::new(self.read_config()?))
    }

    fn read_config(&self) -> Result<ConfigDocument, HimalayaConfigError> {
        if let Some(load_observer) = &self.load_observer {
            load_observer();
        }
        let paths = self.config_paths()?;
        let (first_path, content) = read_first_existing_config(paths)?;
        let raw =
            content
                .parse::<toml::Value>()
                .map_err(|source| HimalayaConfigError::ParseConfig {
                    path: first_path.display().to_string(),
                    source,
                })?;

        Ok(ConfigDocument { raw })
    }

    fn config_paths(&self) -> Result<Vec<PathBuf>, HimalayaConfigError> {
        if let Some(config_paths) = &self.config_paths {
            return Ok(config_paths.clone());
        }

        if let Some(config) = env::var("HIMALAYA_CONFIG").ok().and_then(non_blank) {
            return Ok(config
                .split(':')
                .filter_map(non_blank)
                .map(expand_tilde)
                .collect());
        }

        Ok(default_config_paths())
    }
}

impl fmt::Debug for HimalayaConfigLoader {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HimalayaConfigLoader")
            .field("config_paths", &self.config_paths)
            .field(
                "cached_config_loaded",
                &self
                    .cached_config
                    .as_ref()
                    .and_then(|cache| {
                        cache
                            .lock()
                            .ok()
                            .and_then(|guard| guard.is_some().then_some(()))
                    })
                    .is_some(),
            )
            .field("has_load_observer", &self.load_observer.is_some())
            .finish()
    }
}

impl Default for HimalayaConfigLoader {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone)]
struct ImapSessionPool {
    inner: Arc<ImapSessionPoolInner>,
}

struct ImapSessionPoolInner {
    sessions: Mutex<BTreeMap<ImapSessionKey, Arc<Mutex<ImapClientStd>>>>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct ImapSessionKey {
    account: String,
    server: String,
    starttls: bool,
    alpn: Vec<String>,
    sasl: Option<&'static str>,
}

impl ImapSessionPool {
    fn new() -> Self {
        Self {
            inner: Arc::new(ImapSessionPoolInner {
                sessions: Mutex::new(BTreeMap::new()),
            }),
        }
    }

    fn get_or_connect(
        &self,
        key: ImapSessionKey,
        connect: impl FnOnce() -> Result<ImapClientStd, HimalayaConfigError>,
    ) -> Result<Arc<Mutex<ImapClientStd>>, HimalayaConfigError> {
        if let Some(session) = self.session(&key) {
            return Ok(session);
        }

        let mut client = connect()?;
        let mut sessions = self
            .inner
            .sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match sessions.entry(key) {
            Entry::Occupied(entry) => {
                client.logout().ok();
                Ok(entry.get().clone())
            }
            Entry::Vacant(entry) => {
                let session = Arc::new(Mutex::new(client));
                entry.insert(session.clone());
                Ok(session)
            }
        }
    }

    fn session(&self, key: &ImapSessionKey) -> Option<Arc<Mutex<ImapClientStd>>> {
        self.inner
            .sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(key)
            .cloned()
    }

    fn invalidate(&self, key: &ImapSessionKey) {
        let session = self
            .inner
            .sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(key);
        if let Some(session) = session {
            session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .logout()
                .ok();
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.inner
            .sessions
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .len()
    }
}

impl Drop for ImapSessionPoolInner {
    fn drop(&mut self) {
        let sessions = self
            .sessions
            .get_mut()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for session in sessions.values() {
            session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .logout()
                .ok();
        }
        sessions.clear();
    }
}

impl fmt::Debug for ImapSessionPool {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ImapSessionPool")
            .field("len", &self.len_for_debug())
            .finish()
    }
}

impl ImapSessionPool {
    fn len_for_debug(&self) -> usize {
        self.inner
            .sessions
            .lock()
            .map(|sessions| sessions.len())
            .unwrap_or_default()
    }
}

pub fn default_config_relative_paths() -> [&'static str; 2] {
    ["himalaya/config.toml", ".himalayarc"]
}

pub fn default_config_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    if let Some(config_dir) = dirs::config_dir() {
        paths.push(config_dir.join(PROJECT_NAME).join("config.toml"));
    }

    if let Some(xdg_config_home) = env::var("XDG_CONFIG_HOME").ok().and_then(non_blank) {
        paths.push(
            expand_tilde(xdg_config_home)
                .join(PROJECT_NAME)
                .join("config.toml"),
        );
    }

    if let Some(home) = home_dir() {
        paths.push(home.join(".config").join(PROJECT_NAME).join("config.toml"));
        paths.push(home.join(format!(".{PROJECT_NAME}rc")));
    }

    dedupe_paths(paths)
}

fn read_first_existing_config(
    paths: Vec<PathBuf>,
) -> Result<(PathBuf, String), HimalayaConfigError> {
    for path in paths {
        match fs::read_to_string(&path) {
            Ok(content) => return Ok((path, content)),
            Err(source) if source.kind() == std::io::ErrorKind::NotFound => continue,
            Err(source) => {
                return Err(HimalayaConfigError::ReadConfig {
                    path: path.display().to_string(),
                    source,
                });
            }
        }
    }

    Err(HimalayaConfigError::ConfigNotFound)
}

struct ConfigDocument {
    raw: toml::Value,
}

impl ConfigDocument {
    fn accounts(&self) -> Vec<AccountSummary> {
        let Some(accounts) = self.raw.get("accounts").and_then(toml::Value::as_table) else {
            return Vec::new();
        };

        let mut summaries = accounts
            .iter()
            .filter_map(|(name, value)| account_summary(name, value))
            .collect::<Vec<_>>();
        summaries.sort_by(|left, right| left.name.cmp(&right.name));
        summaries
    }

    fn select_account_table(
        &self,
        account_name: Option<&str>,
    ) -> Result<(AccountSummary, &toml::Table), HimalayaConfigError> {
        let Some(account_tables) = self.raw.get("accounts").and_then(toml::Value::as_table) else {
            return Err(match account_name.and_then(non_blank) {
                Some(account_name) => HimalayaConfigError::AccountNotFound(account_name),
                None => HimalayaConfigError::DefaultAccountNotFound,
            });
        };

        let accounts = self.accounts();
        if let Some(account_name) = account_name.and_then(non_blank) {
            let account = accounts
                .into_iter()
                .find(|account| account.name == account_name)
                .ok_or_else(|| HimalayaConfigError::AccountNotFound(account_name.clone()))?;
            let table = account_tables
                .get(&account.name)
                .and_then(toml::Value::as_table)
                .ok_or_else(|| HimalayaConfigError::AccountNotFound(account.name.clone()))?;
            return Ok((account, table));
        }

        let account = accounts
            .into_iter()
            .find(|account| account.is_default)
            .ok_or(HimalayaConfigError::DefaultAccountNotFound)?;
        let table = account_tables
            .get(&account.name)
            .and_then(toml::Value::as_table)
            .ok_or_else(|| HimalayaConfigError::AccountNotFound(account.name.clone()))?;
        Ok((account, table))
    }
}

fn account_summary(name: &str, value: &toml::Value) -> Option<AccountSummary> {
    let table = value.as_table()?;

    Some(AccountSummary {
        name: name.to_owned(),
        backend: backend_summary(table),
        is_default: table
            .get("default")
            .and_then(toml::Value::as_bool)
            .unwrap_or(false),
        email_address: table
            .get("email")
            .and_then(toml::Value::as_str)
            .and_then(non_blank),
        display_name: table
            .get("display-name")
            .and_then(toml::Value::as_str)
            .and_then(non_blank),
    })
}

fn account_health(account: AccountSummary, _table: &toml::Table) -> AccountHealth {
    let mut issues = Vec::new();
    if account.backend.is_none() {
        issues.push(AccountHealthIssue {
            code: "missing_backend",
            message: format!("Account `{}` does not declare a mail backend", account.name),
        });
    }

    let status = if issues.is_empty() {
        AccountHealthStatus::Ok
    } else {
        AccountHealthStatus::Warning
    };

    AccountHealth {
        account,
        status,
        issues,
    }
}

fn maildir_root(table: &toml::Table) -> Option<PathBuf> {
    if let Some(root) = table
        .get("maildir")
        .and_then(|maildir| maildir.get("root"))
        .and_then(toml::Value::as_str)
        .and_then(non_blank)
    {
        return Some(expand_tilde(root));
    }

    let backend = table.get("backend")?.as_table()?;
    let backend_type = backend
        .get("type")
        .and_then(toml::Value::as_str)
        .and_then(non_blank)?;
    if !backend_type.eq_ignore_ascii_case("maildir") {
        return None;
    }

    for key in ["root", "path"] {
        if let Some(root) = backend
            .get(key)
            .and_then(toml::Value::as_str)
            .and_then(non_blank)
        {
            return Some(expand_tilde(root));
        }
    }

    None
}

fn list_maildir_folders(root: PathBuf) -> Result<Vec<FolderSummary>, HimalayaConfigError> {
    let mut folders = Vec::new();
    collect_maildirs(&root, &root, &mut folders)?;
    folders.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(folders)
}

fn collect_maildirs(
    root: &Path,
    current: &Path,
    folders: &mut Vec<FolderSummary>,
) -> Result<(), HimalayaConfigError> {
    if is_maildir(current) {
        folders.push(FolderSummary {
            name: maildir_display_name(root, current),
            desc: None,
        });
    }

    for entry in fs::read_dir(current).map_err(|source| HimalayaConfigError::ReadConfig {
        path: current.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| HimalayaConfigError::ReadConfig {
            path: current.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir()
            && !matches!(
                path.file_name().and_then(|name| name.to_str()),
                Some("cur" | "new" | "tmp")
            )
        {
            collect_maildirs(root, &path, folders)?;
        }
    }

    Ok(())
}

fn is_maildir(path: &Path) -> bool {
    ["cur", "new", "tmp"]
        .into_iter()
        .all(|component| path.join(component).is_dir())
}

fn maildir_display_name(root: &Path, path: &Path) -> String {
    if path == root {
        return "INBOX".to_owned();
    }

    let relative = path.strip_prefix(root).unwrap_or(path);
    let mut name = relative.to_string_lossy().replace('\\', "/");
    if let Some(stripped) = name.strip_prefix("./") {
        name = stripped.to_owned();
    }
    if let Some(stripped) = name.strip_prefix('.') {
        name = stripped.to_owned();
    }
    name
}

fn list_maildir_messages(
    account: &str,
    root: PathBuf,
    query: MessageListQuery,
) -> Result<Vec<MessageEnvelopeSummary>, HimalayaConfigError> {
    let folder_path = maildir_folder_path(account, &root, &query.folder)?;
    let filter = MessageListFilter::parse(account, query.query.as_deref())?;
    let parser = MessageParser::default();
    let mut messages = Vec::new();

    for subdir in ["new", "cur"] {
        let dir = folder_path.join(subdir);
        for entry in fs::read_dir(&dir).map_err(|source| HimalayaConfigError::ReadConfig {
            path: dir.display().to_string(),
            source,
        })? {
            let entry = entry.map_err(|source| HimalayaConfigError::ReadConfig {
                path: dir.display().to_string(),
                source,
            })?;
            let path = entry.path();
            if !path.is_file() {
                continue;
            }

            let bytes = fs::read(&path).map_err(|source| HimalayaConfigError::ReadConfig {
                path: path.display().to_string(),
                source,
            })?;
            let Some(parsed) = parser.parse(&bytes) else {
                continue;
            };
            let date = parsed.date().and_then(mail_parser_date_to_chrono);
            if !filter.matches(date.as_ref()) {
                continue;
            }

            let id = path
                .file_name()
                .and_then(|name| name.to_str())
                .map(maildir_entry_id)
                .unwrap_or_default()
                .to_owned();
            messages.push(MessageEnvelopeSummary {
                id,
                flags: maildir_flags(&path),
                subject: parsed.subject().map(ToOwned::to_owned),
                from: parsed.from().and_then(first_address),
                to: parsed.to().and_then(first_address),
                date: date.map(format_himalaya_date),
                has_attachment: parsed.attachment_count() > 0,
            });
        }
    }

    messages.sort_by(|left, right| {
        right
            .date
            .cmp(&left.date)
            .then_with(|| right.id.cmp(&left.id))
    });

    let page = query.page.max(1);
    let page_size = query.page_size.unwrap_or(50).max(1);
    let begin = ((page - 1) as usize).saturating_mul(page_size as usize);
    if begin >= messages.len() {
        return Ok(Vec::new());
    }
    let end = messages.len().min(begin + page_size as usize);
    Ok(messages[begin..end].to_vec())
}

fn maildir_folder_path(
    account: &str,
    root: &Path,
    folder: &str,
) -> Result<PathBuf, HimalayaConfigError> {
    validate_maildir_folder(account, folder)?;
    if folder.eq_ignore_ascii_case("INBOX") {
        return Ok(root.to_owned());
    }

    let direct = root.join(folder);
    if is_maildir(&direct) {
        return Ok(direct);
    }

    Ok(root.join(format!(".{folder}")))
}

fn validate_maildir_folder(account: &str, folder: &str) -> Result<(), HimalayaConfigError> {
    let path = Path::new(folder);
    if folder.is_empty()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(HimalayaConfigError::InvalidFolder {
            account: account.to_owned(),
            folder: folder.to_owned(),
        });
    }
    Ok(())
}

fn get_maildir_message(
    account: &str,
    root: PathBuf,
    query: MessageGetQuery,
) -> Result<MessageBodySummary, HimalayaConfigError> {
    let folder_path = maildir_folder_path(account, &root, &query.folder)?;
    let path = maildir_message_path(&folder_path, &query.id)?.ok_or_else(|| {
        HimalayaConfigError::MessageNotFound {
            account: account.to_owned(),
            folder: query.folder.clone(),
            id: query.id.clone(),
        }
    })?;
    let bytes = fs::read(&path).map_err(|source| HimalayaConfigError::ReadConfig {
        path: path.display().to_string(),
        source,
    })?;
    let parser = MessageParser::default();
    let parsed = parser
        .parse(&bytes)
        .ok_or_else(|| HimalayaConfigError::ParseMessage {
            account: account.to_owned(),
            folder: query.folder.clone(),
            id: query.id.clone(),
        })?;

    Ok(MessageBodySummary {
        id: query.id,
        text: parsed.body_text(0).map(|body| body.into_owned()),
        html: parsed.body_html(0).map(|body| body.into_owned()),
        has_attachment: parsed.attachment_count() > 0,
    })
}

fn modify_maildir_message(
    account: &str,
    root: PathBuf,
    command: MessageModifyCommand,
) -> Result<MessageModifySummary, HimalayaConfigError> {
    let source_folder_path = maildir_folder_path(account, &root, &command.folder)?;
    let mut current_path =
        maildir_message_path(&source_folder_path, &command.id)?.ok_or_else(|| {
            HimalayaConfigError::MessageNotFound {
                account: account.to_owned(),
                folder: command.folder.clone(),
                id: command.id.clone(),
            }
        })?;

    if !command.add_flags.is_empty() || !command.remove_flags.is_empty() {
        let mut flags = maildir_flag_letters(&current_path);
        for flag in &command.add_flags {
            flags.push(maildir_flag_letter(account, flag)?);
        }
        for flag in &command.remove_flags {
            let letter = maildir_flag_letter(account, flag)?;
            flags.retain(|existing| *existing != letter);
        }
        flags.sort_unstable();
        flags.dedup();

        let renamed_path = maildir_path_with_flags(&source_folder_path, &current_path, &flags);
        if renamed_path != current_path {
            fs::rename(&current_path, &renamed_path).map_err(|source| {
                HimalayaConfigError::ReadConfig {
                    path: current_path.display().to_string(),
                    source,
                }
            })?;
            current_path = renamed_path;
        }
    }

    let mut folder = command.folder;
    if let Some(target_folder) = command.move_to {
        let target_folder_path = maildir_folder_path(account, &root, &target_folder)?;
        let subdir = current_path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .filter(|name| matches!(*name, "new" | "cur"))
            .unwrap_or("cur");
        let target_path = target_folder_path.join(subdir).join(
            current_path
                .file_name()
                .expect("message path selected from a directory entry"),
        );
        fs::rename(&current_path, &target_path).map_err(|source| {
            HimalayaConfigError::ReadConfig {
                path: current_path.display().to_string(),
                source,
            }
        })?;
        folder = target_folder;
    }

    Ok(MessageModifySummary {
        id: command.id,
        folder,
    })
}

fn download_maildir_attachments(
    account: &str,
    root: PathBuf,
    command: AttachmentDownloadCommand,
) -> Result<Vec<DownloadedAttachmentSummary>, HimalayaConfigError> {
    let folder_path = maildir_folder_path(account, &root, &command.folder)?;
    let path = maildir_message_path(&folder_path, &command.message_id)?.ok_or_else(|| {
        HimalayaConfigError::MessageNotFound {
            account: account.to_owned(),
            folder: command.folder.clone(),
            id: command.message_id.clone(),
        }
    })?;
    let bytes = fs::read(&path).map_err(|source| HimalayaConfigError::ReadConfig {
        path: path.display().to_string(),
        source,
    })?;
    let parser = MessageParser::default();
    let parsed = parser
        .parse(&bytes)
        .ok_or_else(|| HimalayaConfigError::ParseMessage {
            account: account.to_owned(),
            folder: command.folder.clone(),
            id: command.message_id.clone(),
        })?;

    fs::create_dir_all(&command.downloads_dir).map_err(|source| {
        HimalayaConfigError::ReadConfig {
            path: command.downloads_dir.display().to_string(),
            source,
        }
    })?;

    let mut written = Vec::new();
    for (index, part) in parsed.attachments().enumerate() {
        let id = (index + 1).to_string();
        let filename = part.attachment_name().map(ToOwned::to_owned);
        let fallback_name = format!("attachment-{id}");
        let safe = sanitize_attachment_filename(filename.as_deref().unwrap_or(&fallback_name));
        let path = unique_download_path(&command.downloads_dir, &safe);
        fs::write(&path, part.contents()).map_err(|source| HimalayaConfigError::ReadConfig {
            path: path.display().to_string(),
            source,
        })?;
        written.push(DownloadedAttachmentSummary {
            id,
            filename,
            path,
            size: part.contents().len() as u64,
        });
    }

    if written.is_empty() {
        return Err(HimalayaConfigError::AttachmentNotFound {
            account: account.to_owned(),
            folder: command.folder,
            id: command.message_id,
        });
    }

    Ok(written)
}

fn sanitize_attachment_filename(name: &str) -> String {
    let trimmed = name.trim();
    let cleaned = trimmed
        .chars()
        .map(|character| match character {
            '/' | '\\' | '\0' => '_',
            _ => character,
        })
        .collect::<String>();
    let cleaned = cleaned.trim_start_matches('.').trim();
    if cleaned.is_empty() {
        "attachment".to_owned()
    } else {
        cleaned.to_owned()
    }
}

fn unique_download_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }

    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => (stem.to_owned(), format!(".{ext}")),
        _ => (name.to_owned(), String::new()),
    };

    for n in 1..1024 {
        let candidate = dir.join(format!("{stem} ({n}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }

    dir.join(name)
}

fn maildir_path_with_flags(folder_path: &Path, current_path: &Path, flags: &[char]) -> PathBuf {
    let subdir = if flags.contains(&'S') {
        "cur"
    } else {
        current_path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            .filter(|name| matches!(*name, "new" | "cur"))
            .unwrap_or("cur")
    };
    let file_name = current_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let base = file_name
        .split_once(":2,")
        .map(|(base, _)| base)
        .unwrap_or(file_name);
    let flag_string = flags.iter().collect::<String>();
    let file_name = if flag_string.is_empty() {
        base.to_owned()
    } else {
        format!("{base}:2,{flag_string}")
    };

    folder_path.join(subdir).join(file_name)
}

fn maildir_flag_letters(path: &Path) -> Vec<char> {
    path.file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.rsplit_once(":2,").map(|(_, flags)| flags))
        .map(|flags| flags.chars().collect())
        .unwrap_or_default()
}

fn maildir_flag_letter(account: &str, flag: &str) -> Result<char, HimalayaConfigError> {
    match flag.trim().to_ascii_lowercase().as_str() {
        "draft" => Ok('D'),
        "flagged" => Ok('F'),
        "answered" | "replied" => Ok('R'),
        "seen" => Ok('S'),
        "deleted" | "trashed" => Ok('T'),
        unsupported => Err(HimalayaConfigError::MessageFlagUnsupported {
            account: account.to_owned(),
            flag: unsupported.to_owned(),
        }),
    }
}

fn maildir_message_path(
    folder_path: &Path,
    id: &str,
) -> Result<Option<PathBuf>, HimalayaConfigError> {
    for subdir in ["new", "cur"] {
        let dir = folder_path.join(subdir);
        for entry in fs::read_dir(&dir).map_err(|source| HimalayaConfigError::ReadConfig {
            path: dir.display().to_string(),
            source,
        })? {
            let entry = entry.map_err(|source| HimalayaConfigError::ReadConfig {
                path: dir.display().to_string(),
                source,
            })?;
            let path = entry.path();
            if path.is_file()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|file_name| file_name == id || maildir_entry_id(file_name) == id)
            {
                return Ok(Some(path));
            }
        }
    }

    Ok(None)
}

fn maildir_entry_id(file_name: &str) -> &str {
    file_name
        .rsplit_once(":2,")
        .map(|(id, _)| id)
        .unwrap_or(file_name)
}

#[derive(Debug, Clone, Copy)]
struct MessageListFilter {
    after: Option<NaiveDate>,
}

impl MessageListFilter {
    fn parse(account: &str, query: Option<&str>) -> Result<Self, HimalayaConfigError> {
        let Some(query) = query.and_then(non_blank) else {
            return Ok(Self { after: None });
        };
        let parts = query.split_whitespace().collect::<Vec<_>>();
        match parts.as_slice() {
            ["after", date, "order", "by", "date", "desc"] => Ok(Self {
                after: Some(parse_query_date(account, &query, date)?),
            }),
            ["order", "by", "date", "desc"] => Ok(Self { after: None }),
            _ => Err(HimalayaConfigError::MessageQueryUnsupported {
                account: account.to_owned(),
                query,
            }),
        }
    }

    fn matches(&self, date: Option<&chrono::DateTime<FixedOffset>>) -> bool {
        match (self.after, date) {
            (Some(after), Some(date)) => date.date_naive() >= after,
            (Some(_), None) => false,
            (None, _) => true,
        }
    }
}

fn parse_query_date(
    account: &str,
    query: &str,
    date: &str,
) -> Result<NaiveDate, HimalayaConfigError> {
    NaiveDate::parse_from_str(date, "%Y-%m-%d").map_err(|_| {
        HimalayaConfigError::MessageQueryUnsupported {
            account: account.to_owned(),
            query: query.to_owned(),
        }
    })
}

fn mail_parser_date_to_chrono(date: &ParsedDateTime) -> Option<chrono::DateTime<FixedOffset>> {
    let tz_secs = (date.tz_hour as i32) * 3600 + (date.tz_minute as i32) * 60;
    let tz_sign = if date.tz_before_gmt { -1 } else { 1 };
    FixedOffset::east_opt(tz_sign * tz_secs)?
        .with_ymd_and_hms(
            date.year as i32,
            date.month as u32,
            date.day as u32,
            date.hour as u32,
            date.minute as u32,
            date.second as u32,
        )
        .earliest()
}

fn format_himalaya_date(date: chrono::DateTime<FixedOffset>) -> String {
    date.format("%Y-%m-%d %H:%M%:z").to_string()
}

fn first_address(address: &ParsedAddress<'_>) -> Option<MessageAddressSummary> {
    match address {
        ParsedAddress::List(addresses) => addresses.first().and_then(address_summary),
        ParsedAddress::Group(groups) => groups
            .first()
            .and_then(|group| group.addresses.first())
            .and_then(address_summary),
    }
}

fn address_summary(address: &Addr<'_>) -> Option<MessageAddressSummary> {
    Some(MessageAddressSummary {
        name: address.name().map(ToOwned::to_owned),
        addr: address.address()?.to_owned(),
    })
}

fn maildir_flags(path: &Path) -> Vec<String> {
    let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
        return Vec::new();
    };
    let Some((_, flags)) = file_name.rsplit_once(":2,") else {
        return Vec::new();
    };

    let mut result = Vec::new();
    for flag in flags.chars() {
        match flag {
            'D' => result.push("Draft"),
            'F' => result.push("Flagged"),
            'R' => result.push("Answered"),
            'S' => result.push("Seen"),
            'T' => result.push("Deleted"),
            _ => continue,
        }
    }
    result.into_iter().map(ToOwned::to_owned).collect()
}

fn list_imap_folders(
    account: &str,
    table: &toml::Table,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<FolderSummary>, HimalayaConfigError> {
    let imap_value = table
        .get("imap")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(toml::Table::new()));
    let imap: LooseImapConfig =
        imap_value
            .try_into()
            .map_err(|source| HimalayaConfigError::ParseImapConfig {
                account: account.to_owned(),
                source,
            })?;
    list_imap_folders_with_config(account, imap, auth_refresh_observer, imap_session_pool)
}

fn list_imap_messages(
    account: &str,
    table: &toml::Table,
    query: MessageListQuery,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<MessageEnvelopeSummary>, HimalayaConfigError> {
    let imap_value = table
        .get("imap")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(toml::Table::new()));
    let imap: LooseImapConfig =
        imap_value
            .try_into()
            .map_err(|source| HimalayaConfigError::ParseImapConfig {
                account: account.to_owned(),
                source,
            })?;
    list_imap_messages_with_config(
        account,
        imap,
        query,
        auth_refresh_observer,
        imap_session_pool,
    )
}

fn get_imap_message(
    account: &str,
    table: &toml::Table,
    query: MessageGetQuery,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<MessageBodySummary, HimalayaConfigError> {
    let imap_value = table
        .get("imap")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(toml::Table::new()));
    let imap: LooseImapConfig =
        imap_value
            .try_into()
            .map_err(|source| HimalayaConfigError::ParseImapConfig {
                account: account.to_owned(),
                source,
            })?;
    get_imap_message_with_config(
        account,
        imap,
        query,
        auth_refresh_observer,
        imap_session_pool,
    )
}

fn modify_imap_message(
    account: &str,
    table: &toml::Table,
    command: MessageModifyCommand,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<MessageModifySummary, HimalayaConfigError> {
    let imap_value = table
        .get("imap")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(toml::Table::new()));
    let imap: LooseImapConfig =
        imap_value
            .try_into()
            .map_err(|source| HimalayaConfigError::ParseImapConfig {
                account: account.to_owned(),
                source,
            })?;
    modify_imap_message_with_config(
        account,
        imap,
        command,
        auth_refresh_observer,
        imap_session_pool,
    )
}

fn download_imap_attachments(
    account: &str,
    table: &toml::Table,
    command: AttachmentDownloadCommand,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<DownloadedAttachmentSummary>, HimalayaConfigError> {
    let imap_value = table
        .get("imap")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(toml::Table::new()));
    let imap: LooseImapConfig =
        imap_value
            .try_into()
            .map_err(|source| HimalayaConfigError::ParseImapConfig {
                account: account.to_owned(),
                source,
            })?;
    download_imap_attachments_with_config(
        account,
        imap,
        command,
        auth_refresh_observer,
        imap_session_pool,
    )
}

fn list_imap_folders_with_config(
    account: &str,
    imap: LooseImapConfig,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<FolderSummary>, HimalayaConfigError> {
    let key = imap_session_key(account, &imap);
    let session = checkout_imap_client(
        account,
        imap,
        auth_refresh_observer,
        imap_session_pool,
        key.as_ref(),
    )?;
    let reference: Mailbox<'static> = "".try_into().expect("empty mailbox reference is valid");
    let pattern: ListMailbox<'static> = "*".try_into().expect("mailbox wildcard is valid");
    trace_backend("imap_list_start");
    let rows = {
        let mut client = session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        client
            .list(reference, pattern)
            .map_err(|source| HimalayaConfigError::ImapFolderList {
                account: account.to_owned(),
                source,
            })
    };
    let rows = match rows {
        Ok(rows) => rows,
        Err(error) => {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
    };
    trace_backend("imap_list_done");
    if imap_session_pool.is_none() {
        session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .logout()
            .ok();
    }

    let mut folders = rows
        .into_iter()
        .filter_map(|(mailbox, _delimiter, attributes)| {
            if folder_attributes_include_noselect(&attributes) {
                return None;
            }
            Some(FolderSummary {
                name: mailbox_name(mailbox),
                desc: folder_attributes_desc(attributes),
            })
        })
        .collect::<Vec<_>>();
    folders.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(folders)
}

fn connect_imap_client(
    account: &str,
    imap: LooseImapConfig,
    _auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
) -> Result<ImapClientStd, HimalayaConfigError> {
    let server = normalize_imap_server(&imap.server);
    let url = Url::parse(&server).map_err(|source| HimalayaConfigError::ParseImapServerUrl {
        account: account.to_owned(),
        server: imap.server.clone(),
        source,
    })?;
    let tls = Tls {
        rustls: Rustls {
            alpn: imap.alpn.unwrap_or_else(default_alpn),
            ..Rustls::default()
        },
        ..Tls::default()
    };
    let sasl_config = imap.sasl;
    let sasl = sasl_config
        .clone()
        .map(|sasl| sasl.into_sasl(account, &url))
        .transpose()?;

    trace_backend("imap_connect_start");
    let (client, _) =
        ImapClientStd::connect(&url, &tls, imap.starttls, sasl, None).map_err(|source| {
            HimalayaConfigError::ImapConnect {
                account: account.to_owned(),
                source,
            }
        })?;
    trace_backend("imap_connect_done");
    Ok(client)
}

fn imap_session_key(account: &str, imap: &LooseImapConfig) -> Option<ImapSessionKey> {
    Some(ImapSessionKey {
        account: account.to_owned(),
        server: normalize_imap_server(&imap.server),
        starttls: imap.starttls,
        alpn: imap.alpn.clone().unwrap_or_else(default_alpn),
        sasl: imap.sasl.as_ref().map(LooseSaslConfig::session_label),
    })
}

fn checkout_imap_client(
    account: &str,
    imap: LooseImapConfig,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
    key: Option<&ImapSessionKey>,
) -> Result<Arc<Mutex<ImapClientStd>>, HimalayaConfigError> {
    if let (Some(pool), Some(key)) = (imap_session_pool, key) {
        return pool.get_or_connect(key.clone(), || {
            connect_imap_client(account, imap, auth_refresh_observer)
        });
    }

    connect_imap_client(account, imap, auth_refresh_observer)
        .map(|client| Arc::new(Mutex::new(client)))
}

fn invalidate_imap_session(
    imap_session_pool: Option<&ImapSessionPool>,
    key: Option<&ImapSessionKey>,
) {
    if let (Some(pool), Some(key)) = (imap_session_pool, key) {
        pool.invalidate(key);
    }
}

fn list_imap_messages_with_config(
    account: &str,
    imap: LooseImapConfig,
    query: MessageListQuery,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<MessageEnvelopeSummary>, HimalayaConfigError> {
    let mailbox = imap_mailbox(account, &query.folder)?;
    let filter = ImapMessageListFilter::parse(account, query.query.as_deref())?;
    let page = query.page.max(1);
    let page_size = query.page_size.unwrap_or(50).max(1);
    let key = imap_session_key(account, &imap);
    let session = checkout_imap_client(
        account,
        imap,
        auth_refresh_observer,
        imap_session_pool,
        key.as_ref(),
    )?;
    let select = {
        let mut client = session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        client
            .select(mailbox)
            .map_err(|source| HimalayaConfigError::ImapMessageList {
                account: account.to_owned(),
                source,
            })
    };
    let select = match select {
        Ok(select) => select,
        Err(error) => {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
    };
    let ids = if let Some(criteria) = filter.search_criteria(account)? {
        let ids = {
            let mut client = session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            client
                .search(criteria, true)
                .map_err(|source| HimalayaConfigError::ImapMessageList {
                    account: account.to_owned(),
                    source,
                })
        };
        let mut ids = match ids {
            Ok(ids) => ids,
            Err(error) => {
                invalidate_imap_session(imap_session_pool, key.as_ref());
                return Err(error);
            }
        };
        ids.sort_unstable();
        ids.reverse();
        let begin = ((page - 1) as usize).saturating_mul(page_size as usize);
        if begin >= ids.len() {
            if imap_session_pool.is_none() {
                session
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .logout()
                    .ok();
            }
            return Ok(Vec::new());
        }
        ids.into_iter()
            .skip(begin)
            .take(page_size as usize)
            .collect::<Vec<_>>()
    } else {
        let exists = select.exists.unwrap_or(0);
        imap_page_sequence_ids(exists, page, page_size)
    };

    if ids.is_empty() {
        if imap_session_pool.is_none() {
            session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .logout()
                .ok();
        }
        return Ok(Vec::new());
    }

    let item_names = MacroOrMessageDataItemNames::MessageDataItemNames(vec![
        MessageDataItemName::Uid,
        MessageDataItemName::Envelope,
        MessageDataItemName::Flags,
        MessageDataItemName::InternalDate,
    ]);
    let sequence_set =
        SequenceSet::try_from(ids).map_err(|_| HimalayaConfigError::MessageQueryUnsupported {
            account: account.to_owned(),
            query: query.query.unwrap_or_default(),
        })?;
    let data = {
        let mut client = session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        client
            .fetch(sequence_set, item_names, filter.uses_uid_fetch)
            .map_err(|source| HimalayaConfigError::ImapMessageList {
                account: account.to_owned(),
                source,
            })
    };
    let data = match data {
        Ok(data) => data,
        Err(error) => {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
    };
    if imap_session_pool.is_none() {
        session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .logout()
            .ok();
    }

    let mut messages = data
        .into_iter()
        .map(|(seq, items)| imap_envelope_summary(seq.get(), items))
        .collect::<Vec<_>>();
    messages.sort_by(|left, right| {
        right
            .date
            .cmp(&left.date)
            .then_with(|| right.id.cmp(&left.id))
    });
    Ok(messages)
}

fn get_imap_message_with_config(
    account: &str,
    imap: LooseImapConfig,
    query: MessageGetQuery,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<MessageBodySummary, HimalayaConfigError> {
    let raw = fetch_imap_raw_message(
        account,
        imap,
        &query.folder,
        &query.id,
        auth_refresh_observer,
        imap_session_pool,
    )?;
    let parser = MessageParser::default();
    let parsed = parser
        .parse(&raw)
        .ok_or_else(|| HimalayaConfigError::ParseMessage {
            account: account.to_owned(),
            folder: query.folder.clone(),
            id: query.id.clone(),
        })?;

    Ok(MessageBodySummary {
        id: query.id,
        text: parsed.body_text(0).map(|body| body.into_owned()),
        html: parsed.body_html(0).map(|body| body.into_owned()),
        has_attachment: parsed.attachment_count() > 0,
    })
}

fn fetch_imap_raw_message(
    account: &str,
    imap: LooseImapConfig,
    folder: &str,
    id: &str,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<u8>, HimalayaConfigError> {
    let id =
        id.parse::<std::num::NonZeroU32>()
            .map_err(|_| HimalayaConfigError::MessageNotFound {
                account: account.to_owned(),
                folder: folder.to_owned(),
                id: id.to_owned(),
            })?;
    let mailbox = imap_mailbox(account, folder)?;
    let key = imap_session_key(account, &imap);
    let session = checkout_imap_client(
        account,
        imap,
        auth_refresh_observer,
        imap_session_pool,
        key.as_ref(),
    )?;
    let select = {
        let mut client = session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        client
            .select(mailbox)
            .map_err(|source| HimalayaConfigError::ImapMessageGet {
                account: account.to_owned(),
                source,
            })
    };
    if let Err(error) = select {
        invalidate_imap_session(imap_session_pool, key.as_ref());
        return Err(error);
    }
    let item_names =
        MacroOrMessageDataItemNames::MessageDataItemNames(vec![MessageDataItemName::BodyExt {
            section: None,
            partial: None,
            peek: true,
        }]);
    let data = {
        let mut client = session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        client
            .fetch(SequenceSet::from(id), item_names, true)
            .map_err(|source| HimalayaConfigError::ImapMessageGet {
                account: account.to_owned(),
                source,
            })
    };
    let data = match data {
        Ok(data) => data,
        Err(error) => {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
    };
    if imap_session_pool.is_none() {
        session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .logout()
            .ok();
    }
    let raw = data
        .into_values()
        .flat_map(|items| items.into_iter())
        .find_map(|item| match item {
            MessageDataItem::BodyExt { data, .. } => data.0.map(|data| data.as_ref().to_vec()),
            _ => None,
        })
        .unwrap_or_default();
    if raw.is_empty() {
        return Err(HimalayaConfigError::MessageNotFound {
            account: account.to_owned(),
            folder: folder.to_owned(),
            id: id.to_string(),
        });
    }
    Ok(raw)
}

fn modify_imap_message_with_config(
    account: &str,
    imap: LooseImapConfig,
    command: MessageModifyCommand,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<MessageModifySummary, HimalayaConfigError> {
    let id = command.id.parse::<std::num::NonZeroU32>().map_err(|_| {
        HimalayaConfigError::MessageNotFound {
            account: account.to_owned(),
            folder: command.folder.clone(),
            id: command.id.clone(),
        }
    })?;
    let mailbox = imap_mailbox(account, &command.folder)?;
    let add_flags = command
        .add_flags
        .iter()
        .map(|flag| imap_flag(account, flag))
        .collect::<Result<Vec<_>, _>>()?;
    let remove_flags = command
        .remove_flags
        .iter()
        .map(|flag| imap_flag(account, flag))
        .collect::<Result<Vec<_>, _>>()?;
    let destination = command
        .move_to
        .as_deref()
        .map(|target_folder| imap_mailbox(account, target_folder))
        .transpose()?;
    let key = imap_session_key(account, &imap);
    let session = checkout_imap_client(
        account,
        imap,
        auth_refresh_observer,
        imap_session_pool,
        key.as_ref(),
    )?;
    let select = {
        let mut client = session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        client
            .select(mailbox)
            .map_err(|source| HimalayaConfigError::ImapMessageModify {
                account: account.to_owned(),
                source,
            })
    };
    if let Err(error) = select {
        invalidate_imap_session(imap_session_pool, key.as_ref());
        return Err(error);
    }
    let sequence_set = SequenceSet::from(id);

    if !add_flags.is_empty() {
        let result = {
            let mut client = session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            client
                .store(sequence_set.clone(), StoreType::Add, add_flags, true)
                .map_err(|source| HimalayaConfigError::ImapMessageModify {
                    account: account.to_owned(),
                    source,
                })
        };
        if let Err(error) = result {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
    }

    if !remove_flags.is_empty() {
        let result = {
            let mut client = session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            client
                .store(sequence_set.clone(), StoreType::Remove, remove_flags, true)
                .map_err(|source| HimalayaConfigError::ImapMessageModify {
                    account: account.to_owned(),
                    source,
                })
        };
        if let Err(error) = result {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
    }

    let mut folder = command.folder;
    if let Some(target_folder) = command.move_to {
        let destination = destination.expect("destination was validated before checkout");
        let result = {
            let mut client = session
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            client
                .r#move(sequence_set, destination, true)
                .map_err(|source| HimalayaConfigError::ImapMessageModify {
                    account: account.to_owned(),
                    source,
                })
        };
        if let Err(error) = result {
            invalidate_imap_session(imap_session_pool, key.as_ref());
            return Err(error);
        }
        folder = target_folder;
    }
    if imap_session_pool.is_none() {
        session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .logout()
            .ok();
    }

    Ok(MessageModifySummary {
        id: command.id,
        folder,
    })
}

fn download_imap_attachments_with_config(
    account: &str,
    imap: LooseImapConfig,
    command: AttachmentDownloadCommand,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
    imap_session_pool: Option<&ImapSessionPool>,
) -> Result<Vec<DownloadedAttachmentSummary>, HimalayaConfigError> {
    let raw = fetch_imap_raw_message(
        account,
        imap,
        &command.folder,
        &command.message_id,
        auth_refresh_observer,
        imap_session_pool,
    )?;
    let parser = MessageParser::default();
    let parsed = parser
        .parse(&raw)
        .ok_or_else(|| HimalayaConfigError::ParseMessage {
            account: account.to_owned(),
            folder: command.folder.clone(),
            id: command.message_id.clone(),
        })?;

    fs::create_dir_all(&command.downloads_dir).map_err(|source| {
        HimalayaConfigError::ReadConfig {
            path: command.downloads_dir.display().to_string(),
            source,
        }
    })?;

    let mut written = Vec::new();
    for (index, part) in parsed.attachments().enumerate() {
        let id = (index + 1).to_string();
        let filename = part.attachment_name().map(ToOwned::to_owned);
        let fallback_name = format!("attachment-{id}");
        let safe = sanitize_attachment_filename(filename.as_deref().unwrap_or(&fallback_name));
        let path = unique_download_path(&command.downloads_dir, &safe);
        fs::write(&path, part.contents()).map_err(|source| HimalayaConfigError::ReadConfig {
            path: path.display().to_string(),
            source,
        })?;
        written.push(DownloadedAttachmentSummary {
            id,
            filename,
            path,
            size: part.contents().len() as u64,
        });
    }

    if written.is_empty() {
        return Err(HimalayaConfigError::AttachmentNotFound {
            account: account.to_owned(),
            folder: command.folder,
            id: command.message_id,
        });
    }

    Ok(written)
}

fn send_smtp_message(
    account: &str,
    table: &toml::Table,
    raw: Vec<u8>,
    auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
) -> Result<MessageSendSummary, HimalayaConfigError> {
    let smtp_value = table
        .get("smtp")
        .cloned()
        .unwrap_or_else(|| toml::Value::Table(toml::Table::new()));
    let smtp: LooseSmtpConfig =
        smtp_value
            .try_into()
            .map_err(|source| HimalayaConfigError::ParseSmtpConfig {
                account: account.to_owned(),
                source,
            })?;
    send_smtp_message_with_config(account, smtp, raw, auth_refresh_observer)
}

fn send_smtp_message_with_config(
    account: &str,
    smtp: LooseSmtpConfig,
    raw: Vec<u8>,
    _auth_refresh_observer: Option<&Arc<dyn Fn() + Send + Sync>>,
) -> Result<MessageSendSummary, HimalayaConfigError> {
    let (reverse_path, forward_paths) = smtp_envelope(account, &raw)?;
    let server = normalize_smtp_server(&smtp.server);
    let url = Url::parse(&server).map_err(|source| HimalayaConfigError::ParseSmtpServerUrl {
        account: account.to_owned(),
        server: smtp.server.clone(),
        source,
    })?;
    let tls = Tls {
        rustls: Rustls {
            alpn: smtp.alpn.unwrap_or_else(default_smtp_alpn),
            ..Rustls::default()
        },
        ..Tls::default()
    };
    let sasl_config = smtp.sasl;
    let sasl = sasl_config
        .clone()
        .map(|sasl| sasl.into_sasl_for_smtp(account, &url))
        .transpose()?;
    let domain: EhloDomain<'static> = Ipv4Addr::new(127, 0, 0, 1).into();
    let mut client =
        SmtpClientStd::connect(&url, &tls, smtp.starttls, domain, sasl).map_err(|source| {
            HimalayaConfigError::SmtpSend {
                account: account.to_owned(),
                source,
            }
        })?;
    client
        .send(reverse_path, forward_paths, raw)
        .map_err(|source| HimalayaConfigError::SmtpSend {
            account: account.to_owned(),
            source,
        })?;

    Ok(MessageSendSummary { sent: true })
}

fn smtp_envelope(
    account: &str,
    raw: &[u8],
) -> Result<(ReversePath<'static>, Vec<ForwardPath<'static>>), HimalayaConfigError> {
    let Some(headers) = MessageParser::new().parse_headers(raw) else {
        return Err(HimalayaConfigError::InvalidOutgoingMessage {
            account: account.to_owned(),
            message: "invalid message to send".to_owned(),
        });
    };

    let mut mail_from = None;
    let mut rcpt_to = HashSet::new();
    for header in headers.headers() {
        match &header.name {
            HeaderName::From => {
                if let HeaderValue::Address(address) = header.value() {
                    if let Some(email) = first_valid_email(address) {
                        mail_from = Some(email);
                    }
                }
            }
            HeaderName::To | HeaderName::Cc | HeaderName::Bcc => {
                if let HeaderValue::Address(address) = header.value() {
                    collect_valid_emails(address, &mut rcpt_to);
                }
            }
            _ => {}
        }
    }

    let Some(mail_from) = mail_from else {
        return Err(HimalayaConfigError::InvalidOutgoingMessage {
            account: account.to_owned(),
            message: "the message does not contain any sender".to_owned(),
        });
    };
    if rcpt_to.is_empty() {
        return Err(HimalayaConfigError::InvalidOutgoingMessage {
            account: account.to_owned(),
            message: "the message does not contain any recipient".to_owned(),
        });
    }

    let reverse_path = ReversePath::Mailbox(smtp_mailbox(&mail_from).ok_or_else(|| {
        HimalayaConfigError::InvalidOutgoingMessage {
            account: account.to_owned(),
            message: "the message contains an invalid sender".to_owned(),
        }
    })?);
    let mut forward_paths = Vec::new();
    for recipient in rcpt_to {
        let mailbox = smtp_mailbox(&recipient).ok_or_else(|| {
            HimalayaConfigError::InvalidOutgoingMessage {
                account: account.to_owned(),
                message: format!("the message contains an invalid recipient: {recipient}"),
            }
        })?;
        forward_paths.push(ForwardPath(mailbox));
    }

    Ok((reverse_path, forward_paths))
}

fn first_valid_email(address: &ParsedAddress<'_>) -> Option<String> {
    match address {
        ParsedAddress::List(addresses) => addresses.iter().find_map(valid_email),
        ParsedAddress::Group(groups) => groups
            .iter()
            .flat_map(|group| group.addresses.iter())
            .find_map(valid_email),
    }
}

fn collect_valid_emails(address: &ParsedAddress<'_>, output: &mut HashSet<String>) {
    match address {
        ParsedAddress::List(addresses) => output.extend(addresses.iter().filter_map(valid_email)),
        ParsedAddress::Group(groups) => {
            output.extend(
                groups
                    .iter()
                    .flat_map(|group| group.addresses.iter())
                    .filter_map(valid_email),
            );
        }
    }
}

fn valid_email(address: &Addr<'_>) -> Option<String> {
    address
        .address()
        .map(str::trim)
        .and_then(non_blank)
        .filter(|address| address.contains('@'))
}

fn smtp_mailbox(address: &str) -> Option<SmtpMailbox<'static>> {
    let (local, domain) = address.split_once('@')?;
    if local.is_empty() || domain.is_empty() {
        return None;
    }
    Some(SmtpMailbox {
        local_part: LocalPart(Cow::Owned(local.to_owned())),
        domain: EhloDomain::Domain(Domain(Cow::Owned(domain.to_owned()))),
    })
}

fn normalize_imap_server(server: &str) -> String {
    if server.contains("://") {
        server.to_owned()
    } else {
        format!("imaps://{server}")
    }
}

fn normalize_smtp_server(server: &str) -> String {
    if server.contains("://") {
        server.to_owned()
    } else {
        format!("smtps://{server}")
    }
}

fn mailbox_name(mailbox: Mailbox<'static>) -> String {
    match mailbox {
        Mailbox::Inbox => "INBOX".to_owned(),
        Mailbox::Other(other) => String::from_utf8_lossy(other.as_ref()).into_owned(),
    }
}

fn folder_attributes_desc(attributes: Vec<FlagNameAttribute<'static>>) -> Option<String> {
    let attributes = attributes
        .into_iter()
        .map(|attribute| attribute.to_string())
        .collect::<Vec<_>>();
    (!attributes.is_empty()).then(|| attributes.join(", "))
}

fn folder_attributes_include_noselect(attributes: &[FlagNameAttribute<'static>]) -> bool {
    attributes
        .iter()
        .any(|attribute| attribute.to_string().eq_ignore_ascii_case("\\Noselect"))
}

fn imap_mailbox(account: &str, folder: &str) -> Result<Mailbox<'static>, HimalayaConfigError> {
    folder
        .to_owned()
        .try_into()
        .map_err(|_| HimalayaConfigError::InvalidFolder {
            account: account.to_owned(),
            folder: folder.to_owned(),
        })
}

fn imap_page_sequence_ids(exists: u32, page: u32, page_size: u32) -> Vec<std::num::NonZeroU32> {
    if exists == 0 {
        return Vec::new();
    }

    let end = exists.saturating_sub((page - 1).saturating_mul(page_size));
    if end == 0 {
        return Vec::new();
    }
    let start = end.saturating_sub(page_size).saturating_add(1).max(1);
    (start..=end)
        .filter_map(std::num::NonZeroU32::new)
        .collect()
}

struct ImapMessageListFilter {
    since: Option<NaiveDate>,
    address: Option<ImapAddressFilter>,
    uses_uid_fetch: bool,
}

enum ImapAddressFilter {
    From(String),
    To(String),
}

impl ImapMessageListFilter {
    fn parse(account: &str, query: Option<&str>) -> Result<Self, HimalayaConfigError> {
        let Some(query) = query.and_then(non_blank) else {
            return Ok(Self {
                since: None,
                address: None,
                uses_uid_fetch: false,
            });
        };
        let parts = query.split_whitespace().collect::<Vec<_>>();
        match parts.as_slice() {
            ["after", date, "order", "by", "date", "desc"] => Ok(Self {
                since: Some(parse_query_date(account, &query, date)?),
                address: None,
                uses_uid_fetch: true,
            }),
            [
                "after",
                date,
                "and",
                "from",
                address,
                "order",
                "by",
                "date",
                "desc",
            ] => Ok(Self {
                since: Some(parse_query_date(account, &query, date)?),
                address: Some(ImapAddressFilter::From((*address).to_owned())),
                uses_uid_fetch: true,
            }),
            [
                "after",
                date,
                "and",
                "to",
                address,
                "order",
                "by",
                "date",
                "desc",
            ] => Ok(Self {
                since: Some(parse_query_date(account, &query, date)?),
                address: Some(ImapAddressFilter::To((*address).to_owned())),
                uses_uid_fetch: true,
            }),
            ["order", "by", "date", "desc"] => Ok(Self {
                since: None,
                address: None,
                uses_uid_fetch: false,
            }),
            _ => Err(HimalayaConfigError::MessageQueryUnsupported {
                account: account.to_owned(),
                query,
            }),
        }
    }

    fn search_criteria(
        &self,
        account: &str,
    ) -> Result<Option<Vec1<SearchKey<'static>>>, HimalayaConfigError> {
        let mut criteria = Vec::new();
        if let Some(since) = self.since {
            let date = ImapNaiveDate::try_from(since).map_err(|_| {
                HimalayaConfigError::MessageQueryUnsupported {
                    account: account.to_owned(),
                    query: format!("after {since}"),
                }
            })?;
            criteria.push(SearchKey::SentSince(date));
        }
        if let Some(address) = &self.address {
            let key = match address {
                ImapAddressFilter::From(address) => {
                    SearchKey::From(AString::try_from(address.clone()).map_err(|_| {
                        HimalayaConfigError::MessageQueryUnsupported {
                            account: account.to_owned(),
                            query: format!("from {address}"),
                        }
                    })?)
                }
                ImapAddressFilter::To(address) => {
                    SearchKey::To(AString::try_from(address.clone()).map_err(|_| {
                        HimalayaConfigError::MessageQueryUnsupported {
                            account: account.to_owned(),
                            query: format!("to {address}"),
                        }
                    })?)
                }
            };
            criteria.push(key);
        }

        if criteria.is_empty() {
            Ok(None)
        } else {
            Vec1::try_from(criteria).map(Some).map_err(|_| {
                HimalayaConfigError::MessageQueryUnsupported {
                    account: account.to_owned(),
                    query: "empty IMAP search".to_owned(),
                }
            })
        }
    }
}

fn imap_envelope_summary(
    sequence: u32,
    items: Vec1<MessageDataItem<'static>>,
) -> MessageEnvelopeSummary {
    let mut id = sequence.to_string();
    let mut flags = Vec::new();
    let mut subject = None;
    let mut from = None;
    let mut to = None;
    let mut date = None;

    for item in items.into_iter() {
        match item {
            MessageDataItem::Uid(uid) => id = uid.get().to_string(),
            MessageDataItem::Envelope(envelope) => {
                date = envelope
                    .date
                    .into_option()
                    .map(|date| format_imap_date(String::from_utf8_lossy(date.as_ref()).as_ref()));
                subject = envelope
                    .subject
                    .into_option()
                    .and_then(|subject| decode_imap_envelope_subject(subject.as_ref()));
                from = envelope.from.first().and_then(imap_address_summary);
                to = envelope.to.first().and_then(imap_address_summary);
            }
            MessageDataItem::Flags(fetched) => flags = imap_flags(fetched),
            MessageDataItem::InternalDate(internal_date) => {
                if date.is_none() {
                    date = Some(format_himalaya_date(internal_date.as_ref().to_owned()));
                }
            }
            _ => {}
        }
    }

    MessageEnvelopeSummary {
        id,
        flags,
        subject,
        from,
        to,
        date,
        has_attachment: false,
    }
}

fn format_imap_date(raw: &str) -> String {
    chrono::DateTime::parse_from_rfc2822(raw)
        .map(format_himalaya_date)
        .unwrap_or_else(|_| raw.to_owned())
}

fn decode_imap_envelope_subject(raw: &[u8]) -> Option<String> {
    let fallback = String::from_utf8_lossy(raw).to_string();
    let mut header = Vec::with_capacity(b"Subject: ".len() + raw.len() + b"\r\n\r\n".len());
    header.extend_from_slice(b"Subject: ");
    header.extend(
        raw.iter()
            .copied()
            .filter(|byte| !matches!(byte, b'\r' | b'\n')),
    );
    header.extend_from_slice(b"\r\n\r\n");

    MessageParser::new()
        .parse_headers(&header)
        .and_then(|message| message.subject().map(ToOwned::to_owned))
        .and_then(non_blank)
        .or_else(|| non_blank(fallback))
}

fn imap_address_summary(
    address: &io_imap::types::envelope::Address<'_>,
) -> Option<MessageAddressSummary> {
    let mailbox = address
        .mailbox
        .0
        .as_ref()
        .map(|value| String::from_utf8_lossy(value.as_ref()).to_string())
        .and_then(non_blank)?;
    let host = address
        .host
        .0
        .as_ref()
        .map(|value| String::from_utf8_lossy(value.as_ref()).to_string())
        .and_then(non_blank)?;
    let name = address
        .name
        .0
        .as_ref()
        .map(|value| String::from_utf8_lossy(value.as_ref()).to_string())
        .and_then(non_blank);

    Some(MessageAddressSummary {
        name,
        addr: format!("{mailbox}@{host}"),
    })
}

fn imap_flags(flags: Vec<FlagFetch<'static>>) -> Vec<String> {
    flags
        .into_iter()
        .filter_map(|flag| match flag {
            FlagFetch::Flag(Flag::Answered) => Some("Answered"),
            FlagFetch::Flag(Flag::Deleted) => Some("Deleted"),
            FlagFetch::Flag(Flag::Draft) => Some("Draft"),
            FlagFetch::Flag(Flag::Flagged) => Some("Flagged"),
            FlagFetch::Flag(Flag::Seen) => Some("Seen"),
            FlagFetch::Recent => Some("Recent"),
            _ => None,
        })
        .map(ToOwned::to_owned)
        .collect()
}

fn imap_flag(account: &str, flag: &str) -> Result<Flag<'static>, HimalayaConfigError> {
    match flag.trim().to_ascii_lowercase().as_str() {
        "answered" | "replied" => Ok(Flag::Answered),
        "deleted" | "trashed" => Ok(Flag::Deleted),
        "draft" => Ok(Flag::Draft),
        "flagged" => Ok(Flag::Flagged),
        "seen" => Ok(Flag::Seen),
        unsupported => Err(HimalayaConfigError::MessageFlagUnsupported {
            account: account.to_owned(),
            flag: unsupported.to_owned(),
        }),
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseImapConfig {
    server: String,
    #[serde(default)]
    starttls: bool,
    #[serde(default)]
    alpn: Option<Vec<String>>,
    sasl: Option<LooseSaslConfig>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSmtpConfig {
    server: String,
    #[serde(default)]
    starttls: bool,
    #[serde(default)]
    alpn: Option<Vec<String>>,
    sasl: Option<LooseSaslConfig>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum LooseSaslConfig {
    Anonymous(LooseSaslAnonymousConfig),
    Login(LooseSaslLoginConfig),
    Plain(LooseSaslPlainConfig),
    Oauthbearer(LooseSaslOauthbearerConfig),
    Xoauth2(LooseSaslXoauth2Config),
    #[serde(rename = "scram-sha-256")]
    ScramSha256(LooseSaslScramSha256Config),
}

impl LooseSaslConfig {
    fn session_label(&self) -> &'static str {
        match self {
            Self::Anonymous(_) => "anonymous",
            Self::Login(_) => "login",
            Self::Plain(_) => "plain",
            Self::Oauthbearer(_) => "oauthbearer",
            Self::Xoauth2(_) => "xoauth2",
            Self::ScramSha256(_) => "scram-sha-256",
        }
    }

    fn into_sasl(self, account: &str, url: &Url) -> Result<Sasl, HimalayaConfigError> {
        Ok(match self {
            Self::Anonymous(config) => Sasl::Anonymous(SaslAnonymous {
                message: config.message,
            }),
            Self::Login(config) => Sasl::Login(SaslLogin {
                username: config.username,
                password: resolve_secret(account, config.password)?,
            }),
            Self::Plain(config) => Sasl::Plain(SaslPlain {
                authzid: config.authzid,
                authcid: config.authcid,
                passwd: resolve_secret(account, config.passwd)?,
            }),
            Self::Oauthbearer(config) => Sasl::Oauthbearer(SaslOauthbearer {
                username: config.username,
                host: url.host_str().unwrap_or_default().to_owned(),
                port: url.port_or_known_default().unwrap_or(993),
                token: resolve_secret(account, config.token)?,
            }),
            Self::Xoauth2(config) => Sasl::Xoauth2(SaslXoauth2 {
                username: config.username,
                token: resolve_secret(account, config.token)?,
            }),
            Self::ScramSha256(config) => Sasl::ScramSha256(SaslScramSha256 {
                username: config.username,
                password: resolve_secret(account, config.password)?,
            }),
        })
    }

    fn into_sasl_for_smtp(self, account: &str, url: &Url) -> Result<Sasl, HimalayaConfigError> {
        Ok(match self {
            Self::Anonymous(config) => Sasl::Anonymous(SaslAnonymous {
                message: config.message,
            }),
            Self::Login(config) => Sasl::Login(SaslLogin {
                username: config.username,
                password: resolve_smtp_secret(account, config.password)?,
            }),
            Self::Plain(config) => Sasl::Plain(SaslPlain {
                authzid: config.authzid,
                authcid: config.authcid,
                passwd: resolve_smtp_secret(account, config.passwd)?,
            }),
            Self::Oauthbearer(config) => Sasl::Oauthbearer(SaslOauthbearer {
                username: config.username,
                host: url.host_str().unwrap_or_default().to_owned(),
                port: url.port_or_known_default().unwrap_or(587),
                token: resolve_smtp_secret(account, config.token)?,
            }),
            Self::Xoauth2(config) => Sasl::Xoauth2(SaslXoauth2 {
                username: config.username,
                token: resolve_smtp_secret(account, config.token)?,
            }),
            Self::ScramSha256(config) => Sasl::ScramSha256(SaslScramSha256 {
                username: config.username,
                password: resolve_smtp_secret(account, config.password)?,
            }),
        })
    }
}

fn resolve_secret(account: &str, secret: Secret) -> Result<SecretString, HimalayaConfigError> {
    secret
        .get()
        .map_err(|source| HimalayaConfigError::ResolveImapSecret {
            account: account.to_owned(),
            source,
        })
}

fn resolve_smtp_secret(account: &str, secret: Secret) -> Result<SecretString, HimalayaConfigError> {
    secret
        .get()
        .map_err(|source| HimalayaConfigError::ResolveSmtpSecret {
            account: account.to_owned(),
            source,
        })
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSaslAnonymousConfig {
    message: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSaslLoginConfig {
    username: String,
    password: Secret,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSaslPlainConfig {
    authzid: Option<String>,
    #[serde(alias = "username")]
    authcid: String,
    #[serde(alias = "password")]
    passwd: Secret,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSaslOauthbearerConfig {
    username: String,
    token: Secret,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSaslXoauth2Config {
    username: String,
    token: Secret,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
struct LooseSaslScramSha256Config {
    username: String,
    password: Secret,
}

fn trace_backend(event: &str) {
    if env::var("MAILIA_APP_SERVER_TRACE").ok().as_deref() == Some("1") {
        eprintln!("mailia-mail-himalaya: event={event}");
    }
}

fn backend_summary(table: &toml::Table) -> Option<String> {
    let mut receive = Vec::new();
    for (key, label) in [
        ("imap", "IMAP"),
        ("jmap", "JMAP"),
        ("maildir", "Maildir"),
        ("m2dir", "M2dir"),
    ] {
        if table.contains_key(key) {
            receive.push(label);
        }
    }

    let mut send = Vec::new();
    if table.contains_key("smtp") {
        send.push("SMTP");
    }

    dedupe_labels(&mut receive);
    dedupe_labels(&mut send);

    if receive.is_empty() && send.is_empty() {
        return None;
    }

    let receive = if receive.is_empty() {
        "None".to_owned()
    } else {
        receive.join("+")
    };
    let send = if send.is_empty() {
        "None".to_owned()
    } else {
        send.join("+")
    };
    Some(format!("{receive}, {send}"))
}

fn dedupe_labels(labels: &mut Vec<&'static str>) {
    let mut counts = BTreeMap::new();
    labels.retain(|label| counts.insert(*label, ()).is_none());
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = Vec::<PathBuf>::new();
    for path in paths {
        if !seen.contains(&path) {
            seen.push(path);
        }
    }
    seen
}

fn non_blank(value: impl AsRef<str>) -> Option<String> {
    let value = value.as_ref().trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn expand_tilde(path: String) -> PathBuf {
    if path == "~" {
        return home_dir().unwrap_or_else(|| PathBuf::from(path));
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return home_dir()
            .map(|home| home.join(rest))
            .unwrap_or_else(|| PathBuf::from(path));
    }
    PathBuf::from(path)
}

fn home_dir() -> Option<PathBuf> {
    env::var("HOME").ok().and_then(non_blank).map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        sync::atomic::{AtomicU64, Ordering},
        thread,
    };

    static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn reads_v2_account_backend_summary() {
        let path = write_config(
            r#"
            [accounts.personal]
            imap.server = "imap.example.com"
            smtp.server = "smtp.example.com"

            [accounts.archive]
            maildir.root = "~/Mail/archive"
            "#,
        );

        let accounts = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .load_accounts()
            .unwrap();
        std::fs::remove_file(path).ok();

        assert_eq!(accounts.len(), 2);
        assert_eq!(accounts[0].name, "archive");
        assert_eq!(accounts[0].backend.as_deref(), Some("Maildir, None"));
        assert_eq!(accounts[1].name, "personal");
        assert_eq!(accounts[1].backend.as_deref(), Some("IMAP, SMTP"));
    }

    #[test]
    fn cached_loader_reuses_the_first_loaded_config_document() {
        let path = write_config(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap.example.com"
            "#,
        );
        let load_count = Arc::new(AtomicU64::new(0));
        let observed_load_count = load_count.clone();
        let loader = HimalayaConfigLoader::cached_with_config_paths_and_load_observer(
            vec![path.clone()],
            Arc::new(move || {
                observed_load_count.fetch_add(1, Ordering::SeqCst);
            }),
        );

        let first = loader.load_accounts().unwrap();
        std::fs::write(
            &path,
            r#"
            [accounts.personal]
            default = true
            maildir.root = "~/Mail/personal"
            "#,
        )
        .unwrap();
        let second = loader.load_accounts().unwrap();
        std::fs::remove_file(path).ok();

        assert_eq!(load_count.load(Ordering::SeqCst), 1);
        assert_eq!(first, second);
        assert_eq!(second[0].name, "work");
    }

    #[test]
    fn missing_config_is_reported() {
        let missing = PathBuf::from("/tmp/mailia-missing-config-for-test.toml");
        let error = HimalayaConfigLoader::with_config_paths(vec![missing])
            .load_accounts()
            .unwrap_err();

        assert!(matches!(error, HimalayaConfigError::ConfigNotFound));
    }

    #[test]
    fn account_health_uses_named_account() {
        let path = write_config(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap.example.com"

            [accounts.personal]
            "#,
        );

        let health = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .account_health(Some("personal"))
            .unwrap();
        std::fs::remove_file(path).ok();

        assert_eq!(health.account.name, "personal");
        assert_eq!(health.status, AccountHealthStatus::Warning);
        assert_eq!(health.issues[0].code, "missing_backend");
    }

    #[test]
    fn account_health_uses_default_account_when_name_is_omitted() {
        let path = write_config(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap.example.com"

            [accounts.personal]
            "#,
        );

        let health = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .account_health(None)
            .unwrap();
        std::fs::remove_file(path).ok();

        assert_eq!(health.account.name, "work");
        assert_eq!(health.status, AccountHealthStatus::Ok);
        assert!(health.issues.is_empty());
    }

    #[test]
    fn account_health_reports_unknown_account() {
        let path = write_config(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap.example.com"
            "#,
        );

        let error = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .account_health(Some("personal"))
            .unwrap_err();
        std::fs::remove_file(path).ok();

        assert!(matches!(error, HimalayaConfigError::AccountNotFound(name) if name == "personal"));
    }

    #[test]
    fn lists_v2_maildir_folders_from_filesystem() {
        let root = temp_maildir_root();
        make_maildir(&root);
        make_maildir(&root.join("Archive"));
        make_maildir(&root.join(".Projects").join("Client"));
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let folders = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .folder_list(Some("local"))
            .unwrap();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert_eq!(
            folders,
            vec![
                FolderSummary {
                    name: "Archive".to_owned(),
                    desc: None,
                },
                FolderSummary {
                    name: "INBOX".to_owned(),
                    desc: None,
                },
                FolderSummary {
                    name: "Projects/Client".to_owned(),
                    desc: None,
                },
            ]
        );
    }

    #[test]
    fn lists_maildir_messages_with_date_query_sorting_and_paging() {
        let root = temp_maildir_root();
        make_maildir(&root);
        write_maildir_message(
            &root,
            "cur/old:2,S",
            "Old",
            "Fri, 29 May 2026 04:55:00 +0000",
        );
        write_maildir_message(
            &root,
            "cur/newer:2,SF",
            "Newer",
            "Sat, 30 May 2026 05:10:00 +0000",
        );
        write_maildir_message(
            &root,
            "new/newest",
            "Newest",
            "Sat, 30 May 2026 06:10:00 +0000",
        );
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let loader = HimalayaConfigLoader::with_config_paths(vec![path.clone()]);
        let messages = loader
            .message_list(MessageListQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                query: Some("after 2026-05-30 order by date desc".to_owned()),
                page: 1,
                page_size: Some(1),
            })
            .unwrap();
        let second_page = loader
            .message_list(MessageListQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                query: Some("after 2026-05-30 order by date desc".to_owned()),
                page: 2,
                page_size: Some(1),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].id, "newest");
        assert_eq!(messages[0].subject.as_deref(), Some("Newest"));
        assert_eq!(
            messages[0].from.as_ref().unwrap().addr,
            "sender@example.com"
        );
        assert_eq!(
            messages[0].to.as_ref().unwrap().addr,
            "recipient@example.net"
        );
        assert_eq!(messages[0].date.as_deref(), Some("2026-05-30 06:10+00:00"));
        assert!(!messages[0].has_attachment);
        assert_eq!(second_page.len(), 1);
        assert_eq!(second_page[0].id, "newer");
        assert_eq!(second_page[0].flags, vec!["Seen", "Flagged"]);
    }

    #[test]
    fn rejects_unsupported_maildir_message_query() {
        let root = temp_maildir_root();
        make_maildir(&root);
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let error = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_list(MessageListQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                query: Some("from sender@example.com".to_owned()),
                page: 1,
                page_size: Some(1),
            })
            .unwrap_err();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert!(
            matches!(error, HimalayaConfigError::MessageQueryUnsupported { account, query }
                if account == "local" && query == "from sender@example.com")
        );
    }

    #[test]
    fn gets_maildir_message_body_by_exact_filename_id() {
        let root = temp_maildir_root();
        make_maildir(&root);
        write_maildir_raw_message(
            &root,
            "cur/body:2,S",
            "From: Sender <sender@example.com>\r\n\
             To: Recipient <recipient@example.net>\r\n\
             Subject: Body\r\n\
             Date: Sat, 30 May 2026 06:10:00 +0000\r\n\
             MIME-Version: 1.0\r\n\
             Content-Type: multipart/alternative; boundary=\"mailia-boundary\"\r\n\
             \r\n\
             --mailia-boundary\r\n\
             Content-Type: text/plain; charset=utf-8\r\n\
             \r\n\
             Plain body\r\n\
             --mailia-boundary\r\n\
             Content-Type: text/html; charset=utf-8\r\n\
             \r\n\
             <p>HTML body</p>\r\n\
             --mailia-boundary--\r\n",
        );
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let message = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_get(MessageGetQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "body".to_owned(),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert_eq!(message.id, "body");
        assert_eq!(message.text.as_deref(), Some("Plain body"));
        assert_eq!(message.html.as_deref(), Some("<p>HTML body</p>"));
        assert!(!message.has_attachment);
    }

    #[test]
    fn maildir_message_get_does_not_treat_id_as_path() {
        let root = temp_maildir_root();
        make_maildir(&root);
        write_maildir_message(
            &root,
            "cur/body:2,S",
            "Body",
            "Sat, 30 May 2026 06:10:00 +0000",
        );
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let error = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_get(MessageGetQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "../cur/body".to_owned(),
            })
            .unwrap_err();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert!(
            matches!(error, HimalayaConfigError::MessageNotFound { account, folder, id }
                if account == "local" && folder == "INBOX" && id == "../cur/body")
        );
    }

    #[test]
    fn modifies_maildir_message_flags_using_stable_id() {
        let root = temp_maildir_root();
        make_maildir(&root);
        write_maildir_message(&root, "new/body", "Body", "Sat, 30 May 2026 06:10:00 +0000");
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let loader = HimalayaConfigLoader::with_config_paths(vec![path.clone()]);
        let modified = loader
            .message_modify(MessageModifyCommand {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "body".to_owned(),
                add_flags: vec!["seen".to_owned(), "flagged".to_owned()],
                remove_flags: Vec::new(),
                move_to: None,
            })
            .unwrap();
        let unflagged = loader
            .message_modify(MessageModifyCommand {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "body".to_owned(),
                add_flags: Vec::new(),
                remove_flags: vec!["flagged".to_owned()],
                move_to: None,
            })
            .unwrap();
        let message = loader
            .message_get(MessageGetQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "body".to_owned(),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert_eq!(modified.id, "body");
        assert_eq!(modified.folder, "INBOX");
        assert_eq!(unflagged.id, "body");
        assert_eq!(message.id, "body");
    }

    #[test]
    fn moves_maildir_message_between_folders() {
        let root = temp_maildir_root();
        make_maildir(&root);
        make_maildir(&root.join("Archive"));
        write_maildir_message(
            &root,
            "cur/body:2,S",
            "Body",
            "Sat, 30 May 2026 06:10:00 +0000",
        );
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let loader = HimalayaConfigLoader::with_config_paths(vec![path.clone()]);
        let modified = loader
            .message_modify(MessageModifyCommand {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "body".to_owned(),
                add_flags: Vec::new(),
                remove_flags: Vec::new(),
                move_to: Some("Archive".to_owned()),
            })
            .unwrap();
        let message = loader
            .message_get(MessageGetQuery {
                account: Some("local".to_owned()),
                folder: "Archive".to_owned(),
                id: "body".to_owned(),
            })
            .unwrap();
        let source_error = loader
            .message_get(MessageGetQuery {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                id: "body".to_owned(),
            })
            .unwrap_err();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert_eq!(modified.folder, "Archive");
        assert_eq!(message.id, "body");
        assert!(matches!(
            source_error,
            HimalayaConfigError::MessageNotFound { .. }
        ));
    }

    #[test]
    fn downloads_maildir_attachments_with_sanitized_unique_names() {
        let root = temp_maildir_root();
        let downloads = temp_maildir_root();
        make_maildir(&root);
        fs::write(downloads.join("unsafe_name.txt"), "existing").unwrap();
        write_maildir_raw_message(
            &root,
            "cur/body:2,S",
            "From: Sender <sender@example.com>\r\n\
             To: Recipient <recipient@example.net>\r\n\
             Subject: Body\r\n\
             Date: Sat, 30 May 2026 06:10:00 +0000\r\n\
             MIME-Version: 1.0\r\n\
             Content-Type: multipart/mixed; boundary=\"mailia-boundary\"\r\n\
             \r\n\
             --mailia-boundary\r\n\
             Content-Type: text/plain; charset=utf-8\r\n\
             \r\n\
             Plain body\r\n\
             --mailia-boundary\r\n\
             Content-Type: text/plain; name=\"unsafe/name.txt\"\r\n\
             Content-Disposition: attachment; filename=\"unsafe/name.txt\"\r\n\
             \r\n\
             Attachment body\r\n\
             --mailia-boundary--\r\n",
        );
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let attachments = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .attachment_download(AttachmentDownloadCommand {
                account: Some("local".to_owned()),
                folder: "INBOX".to_owned(),
                message_id: "body".to_owned(),
                downloads_dir: downloads.clone(),
            })
            .unwrap();
        let written = fs::read_to_string(downloads.join("unsafe_name (1).txt")).unwrap();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();
        std::fs::remove_dir_all(downloads).ok();

        assert_eq!(attachments.len(), 1);
        assert_eq!(attachments[0].id, "1");
        assert_eq!(attachments[0].filename.as_deref(), Some("unsafe/name.txt"));
        assert!(attachments[0].path.ends_with("unsafe_name (1).txt"));
        assert_eq!(attachments[0].size, "Attachment body".len() as u64);
        assert_eq!(written, "Attachment body");
    }

    #[test]
    fn extracts_smtp_envelope_from_raw_message_headers() {
        let raw = b"From: Sender <sender@example.com>\r\nTo: One <one@example.net>\r\nCc: two@example.net\r\nBcc: two@example.net\r\nSubject: Hello\r\n\r\nBody";

        let (reverse_path, forward_paths) = smtp_envelope("work", raw).unwrap();
        let mut recipients = forward_paths
            .into_iter()
            .map(|path| path.to_string())
            .collect::<Vec<_>>();
        recipients.sort();

        assert_eq!(reverse_path.to_string(), "<sender@example.com>");
        assert_eq!(recipients, vec!["<one@example.net>", "<two@example.net>"]);
    }

    #[test]
    fn rejects_smtp_message_without_recipient() {
        let error = smtp_envelope("work", b"From: sender@example.com\r\n\r\nBody").unwrap_err();

        assert!(matches!(
            error,
            HimalayaConfigError::InvalidOutgoingMessage { account, message }
                if account == "work" && message == "the message does not contain any recipient"
        ));
    }

    #[test]
    fn rejects_maildir_folder_path_traversal() {
        let root = temp_maildir_root();
        make_maildir(&root);
        let escaped_root = root.to_string_lossy().replace('\\', "\\\\");
        let path = write_config(&format!(
            r#"
            [accounts.local]
            default = true
            maildir.root = "{escaped_root}"
            "#
        ));

        let error = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_list(MessageListQuery {
                account: Some("local".to_owned()),
                folder: "../outside".to_owned(),
                query: None,
                page: 1,
                page_size: Some(1),
            })
            .unwrap_err();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(root).ok();

        assert!(
            matches!(error, HimalayaConfigError::InvalidFolder { account, folder }
                if account == "local" && folder == "../outside")
        );
    }

    #[test]
    fn folder_list_reports_unsupported_backend() {
        let path = write_config(
            r#"
            [accounts.work]
            default = true
            jmap.server = "api.example.com"
            "#,
        );

        let error = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .folder_list(Some("work"))
            .unwrap_err();
        std::fs::remove_file(path).ok();

        assert!(
            matches!(error, HimalayaConfigError::FolderBackendUnsupported { account, backend }
                if account == "work" && backend == "JMAP, None")
        );
    }

    #[test]
    fn folder_list_reports_invalid_imap_server_before_connecting() {
        let path = write_config(
            r#"
            [accounts.work]
            default = true
            imap.server = "not a valid server"
            "#,
        );

        let error = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .folder_list(Some("work"))
            .unwrap_err();
        std::fs::remove_file(path).ok();

        assert!(
            matches!(error, HimalayaConfigError::ParseImapServerUrl { account, .. }
                if account == "work")
        );
    }

    #[test]
    fn imap_client_std_is_safe_for_mutex_backed_session_pool() {
        fn assert_send<T: Send>() {}
        fn assert_sync<T: Sync>() {}

        assert_send::<ImapClientStd>();
        assert_send::<Arc<Mutex<ImapClientStd>>>();
        assert_sync::<Arc<Mutex<ImapClientStd>>>();
        assert_send::<ImapSessionPool>();
        assert_sync::<ImapSessionPool>();
    }

    #[test]
    fn cached_loader_reuses_imap_session_between_message_gets() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let raw_one = "From: Sender <sender@example.com>\r\n\
                       To: Recipient <recipient@example.net>\r\n\
                       Subject: First\r\n\
                       MIME-Version: 1.0\r\n\
                       Content-Type: text/plain; charset=utf-8\r\n\
                       \r\n\
                       First body";
        let raw_two = "From: Sender <sender@example.com>\r\n\
                       To: Recipient <recipient@example.net>\r\n\
                       Subject: Second\r\n\
                       MIME-Version: 1.0\r\n\
                       Content-Type: text/plain; charset=utf-8\r\n\
                       \r\n\
                       Second body";
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            for raw in [raw_one, raw_two] {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                assert!(line.contains("SELECT"));
                let tag = line.split_whitespace().next().unwrap().to_owned();
                stream
                    .write_all(
                        format!("* 2 EXISTS\r\n{tag} OK [READ-WRITE] SELECT completed\r\n")
                            .as_bytes(),
                    )
                    .unwrap();

                line.clear();
                reader.read_line(&mut line).unwrap();
                assert!(line.contains("FETCH"));
                let tag = line.split_whitespace().next().unwrap().to_owned();
                stream
                    .write_all(
                        format!(
                            "* 1 FETCH (BODY[] {{{}}}\r\n{})\r\n{tag} OK FETCH completed\r\n",
                            raw.len(),
                            raw
                        )
                        .as_bytes(),
                    )
                    .unwrap();
            }

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("LOGOUT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));
        let loader = HimalayaConfigLoader::cached_with_config_paths_and_load_observer(
            vec![path.clone()],
            Arc::new(|| {}),
        );

        let first = loader
            .message_get(MessageGetQuery {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                id: "1".to_owned(),
            })
            .unwrap();
        let second = loader
            .message_get(MessageGetQuery {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                id: "2".to_owned(),
            })
            .unwrap();
        assert_eq!(loader.imap_session_pool.as_ref().unwrap().len(), 1);

        drop(loader);
        std::fs::remove_file(path).ok();
        server.join().unwrap();

        assert_eq!(first.text.as_deref(), Some("First body"));
        assert_eq!(second.text.as_deref(), Some("Second body"));
    }

    #[test]
    fn cached_loader_invalidates_imap_session_after_fetch_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let raw = "From: Sender <sender@example.com>\r\n\
                   To: Recipient <recipient@example.net>\r\n\
                   Subject: Reconnected\r\n\
                   MIME-Version: 1.0\r\n\
                   Content-Type: text/plain; charset=utf-8\r\n\
                   \r\n\
                   Reconnected body";
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SELECT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* 1 EXISTS\r\n{tag} OK SELECT completed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("FETCH"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("{tag} NO FETCH failed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("LOGOUT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();

            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SELECT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* 1 EXISTS\r\n{tag} OK SELECT completed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("FETCH"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!(
                        "* 1 FETCH (BODY[] {{{}}}\r\n{})\r\n{tag} OK FETCH completed\r\n",
                        raw.len(),
                        raw
                    )
                    .as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("LOGOUT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));
        let loader = HimalayaConfigLoader::cached_with_config_paths_and_load_observer(
            vec![path.clone()],
            Arc::new(|| {}),
        );

        let error = loader
            .message_get(MessageGetQuery {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                id: "1".to_owned(),
            })
            .unwrap_err();
        assert!(matches!(
            error,
            HimalayaConfigError::ImapMessageGet { account, .. } if account == "work"
        ));
        assert_eq!(loader.imap_session_pool.as_ref().unwrap().len(), 0);

        let message = loader
            .message_get(MessageGetQuery {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                id: "1".to_owned(),
            })
            .unwrap();

        drop(loader);
        std::fs::remove_file(path).ok();
        server.join().unwrap();

        assert_eq!(message.text.as_deref(), Some("Reconnected body"));
    }

    #[test]
    fn lists_v2_imap_folders_using_io_imap_backend() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("LIST"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!(
                        "* LIST (\\HasNoChildren) \"/\" INBOX\r\n\
	                         * LIST (\\HasChildren \\Noselect) \"/\" \"[Gmail]\"\r\n\
	                         * LIST (\\HasNoChildren \\Sent) \"/\" Sent\r\n\
	                         {tag} OK LIST completed\r\n"
                    )
                    .as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));

        let folders = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .folder_list(Some("work"))
            .unwrap();
        std::fs::remove_file(path).ok();
        server.join().unwrap();

        assert_eq!(folders.len(), 2);
        assert_eq!(folders[0].name, "INBOX");
        assert_eq!(folders[1].name, "Sent");
        assert!(!folders.iter().any(|folder| folder.name == "[Gmail]"));
        assert!(
            folders[1]
                .desc
                .as_deref()
                .unwrap_or_default()
                .contains("Sent")
        );
    }

    #[test]
    fn lists_v2_imap_messages_using_io_imap_backend() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let encoded_subject = "=?UTF-8?Q?=E6=82=A8=E4=B8=8E=E2=80=9Cgreasyfork.org?= =?UTF-8?Q?=E2=80=9D=E5=85=B1=E4=BA=AB=E4=BA=86=E4=B8=80=E4=BA=9B_Go?= =?UTF-8?Q?ogle_=E8=B4=A6=E5=8F=B7=E6=95=B0=E6=8D=AE?=";
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SELECT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!("* 2 EXISTS\r\n{tag} OK [READ-WRITE] SELECT completed\r\n").as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SEARCH"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* SEARCH 1 2\r\n{tag} OK SEARCH completed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("FETCH"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!(
                        "* 1 FETCH (UID 1 FLAGS (\\Seen) INTERNALDATE \"29-May-2026 04:55:00 +0000\" ENVELOPE (\"Fri, 29 May 2026 04:55:00 +0000\" \"Older\" ((\"Sender\" NIL \"sender\" \"example.com\")) ((\"Sender\" NIL \"sender\" \"example.com\")) ((\"Sender\" NIL \"sender\" \"example.com\")) ((\"Recipient\" NIL \"recipient\" \"example.net\")) NIL NIL NIL \"<old@example.com>\"))\r\n\
                         * 2 FETCH (UID 2 FLAGS (\\Seen \\Flagged) INTERNALDATE \"30-May-2026 06:10:00 +0000\" ENVELOPE (\"Sat, 30 May 2026 06:10:00 +0000\" \"{encoded_subject}\" ((\"Sender\" NIL \"sender\" \"example.com\")) ((\"Sender\" NIL \"sender\" \"example.com\")) ((\"Sender\" NIL \"sender\" \"example.com\")) ((\"Recipient\" NIL \"recipient\" \"example.net\")) NIL NIL NIL \"<new@example.com>\"))\r\n\
                         {tag} OK FETCH completed\r\n"
                    )
                    .as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));

        let messages = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_list(MessageListQuery {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                query: Some("after 2026-05-29 order by date desc".to_owned()),
                page: 1,
                page_size: Some(2),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        server.join().unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].id, "2");
        assert_eq!(
            messages[0].subject.as_deref(),
            Some(
                "\u{60a8}\u{4e0e}\u{201c}greasyfork.org\u{201d}\u{5171}\u{4eab}\u{4e86}\u{4e00}\u{4e9b} Google \u{8d26}\u{53f7}\u{6570}\u{636e}"
            )
        );
        assert_eq!(messages[0].flags, vec!["Seen", "Flagged"]);
        assert_eq!(messages[0].date.as_deref(), Some("2026-05-30 06:10+00:00"));
        assert_eq!(
            messages[0].from.as_ref().unwrap().addr,
            "sender@example.com"
        );
        assert_eq!(
            messages[0].to.as_ref().unwrap().addr,
            "recipient@example.net"
        );
        assert_eq!(messages[1].id, "1");
    }

    #[test]
    fn gets_v2_imap_message_body_using_io_imap_backend() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let raw = "From: Sender <sender@example.com>\r\n\
                   To: Recipient <recipient@example.net>\r\n\
                   Subject: Body\r\n\
                   MIME-Version: 1.0\r\n\
                   Content-Type: text/plain; charset=utf-8\r\n\
                   \r\n\
                   Plain body";
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SELECT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!("* 1 EXISTS\r\n{tag} OK [READ-WRITE] SELECT completed\r\n").as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("FETCH"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!(
                        "* 1 FETCH (BODY[] {{{}}}\r\n{})\r\n{tag} OK FETCH completed\r\n",
                        raw.len(),
                        raw
                    )
                    .as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));

        let message = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_get(MessageGetQuery {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                id: "1".to_owned(),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        server.join().unwrap();

        assert_eq!(message.id, "1");
        assert_eq!(message.text.as_deref(), Some("Plain body"));
        assert_eq!(
            message.html.as_deref(),
            Some("<html><body>Plain body</body></html>")
        );
        assert!(!message.has_attachment);
    }

    #[test]
    fn modifies_v2_imap_message_flags_and_move_using_io_imap_backend() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1 MOVE] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SELECT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!("* 1 EXISTS\r\n{tag} OK [READ-WRITE] SELECT completed\r\n").as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("UID STORE 7"));
            assert!(line.contains("+FLAGS"));
            assert!(line.contains("\\Seen"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("{tag} OK STORE completed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("UID STORE 7"));
            assert!(line.contains("-FLAGS"));
            assert!(line.contains("\\Flagged"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("{tag} OK STORE completed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("UID MOVE 7 Archive"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("{tag} OK MOVE completed\r\n").as_bytes())
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));

        let modified = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_modify(MessageModifyCommand {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                id: "7".to_owned(),
                add_flags: vec!["seen".to_owned()],
                remove_flags: vec!["flagged".to_owned()],
                move_to: Some("Archive".to_owned()),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        server.join().unwrap();

        assert_eq!(modified.id, "7");
        assert_eq!(modified.folder, "Archive");
    }

    #[test]
    fn downloads_v2_imap_attachments_using_io_imap_backend() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let downloads = temp_maildir_root();
        let raw = "From: Sender <sender@example.com>\r\n\
                   To: Recipient <recipient@example.net>\r\n\
                   Subject: Attachment\r\n\
                   MIME-Version: 1.0\r\n\
                   Content-Type: multipart/mixed; boundary=\"mailia-boundary\"\r\n\
                   \r\n\
                   --mailia-boundary\r\n\
                   Content-Type: text/plain; charset=utf-8\r\n\
                   \r\n\
                   Plain body\r\n\
                   --mailia-boundary\r\n\
                   Content-Type: text/plain; name=\"unsafe/name.txt\"\r\n\
                   Content-Disposition: attachment; filename=\"unsafe/name.txt\"\r\n\
                   \r\n\
                   Attachment body\r\n\
                   --mailia-boundary--\r\n";
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .write_all(b"* OK [CAPABILITY IMAP4rev1] mailia test server\r\n")
                .unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("SELECT"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!("* 1 EXISTS\r\n{tag} OK [READ-WRITE] SELECT completed\r\n").as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("FETCH"));
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(
                    format!(
                        "* 1 FETCH (BODY[] {{{}}}\r\n{})\r\n{tag} OK FETCH completed\r\n",
                        raw.len(),
                        raw
                    )
                    .as_bytes(),
                )
                .unwrap();

            line.clear();
            reader.read_line(&mut line).unwrap();
            let tag = line.split_whitespace().next().unwrap().to_owned();
            stream
                .write_all(format!("* BYE logging out\r\n{tag} OK LOGOUT completed\r\n").as_bytes())
                .unwrap();
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            imap.server = "imap://{address}"
            "#
        ));

        let attachments = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .attachment_download(AttachmentDownloadCommand {
                account: Some("work".to_owned()),
                folder: "INBOX".to_owned(),
                message_id: "1".to_owned(),
                downloads_dir: downloads.clone(),
            })
            .unwrap();
        let written = fs::read_to_string(downloads.join("unsafe_name.txt")).unwrap();
        std::fs::remove_file(path).ok();
        std::fs::remove_dir_all(downloads).ok();
        server.join().unwrap();

        assert_eq!(attachments.len(), 1);
        assert_eq!(attachments[0].id, "1");
        assert_eq!(attachments[0].filename.as_deref(), Some("unsafe/name.txt"));
        assert_eq!(attachments[0].size, "Attachment body".len() as u64);
        assert_eq!(written, "Attachment body");
    }

    #[test]
    fn sends_raw_message_using_v2_smtp_backend() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(b"220 localhost ESMTP\r\n").unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut commands = Vec::new();
            let mut data = String::new();

            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            commands.push(line.trim_end().to_owned());
            stream.write_all(b"250-localhost\r\n250 SIZE\r\n").unwrap();

            loop {
                line.clear();
                reader.read_line(&mut line).unwrap();
                let trimmed = line.trim_end().to_owned();
                commands.push(trimmed.clone());
                if trimmed.starts_with("MAIL FROM:") || trimmed.starts_with("RCPT TO:") {
                    stream.write_all(b"250 OK\r\n").unwrap();
                } else if trimmed == "DATA" {
                    stream.write_all(b"354 End data\r\n").unwrap();
                    break;
                } else {
                    panic!("unexpected SMTP command: {trimmed}");
                }
            }

            loop {
                line.clear();
                reader.read_line(&mut line).unwrap();
                if line == ".\r\n" {
                    break;
                }
                data.push_str(&line);
            }
            stream.write_all(b"250 OK\r\n").unwrap();
            (commands, data)
        });
        let path = write_config(&format!(
            r#"
            [accounts.work]
            default = true
            smtp.server = "smtp://{address}"
            "#
        ));

        let result = HimalayaConfigLoader::with_config_paths(vec![path.clone()])
            .message_send(MessageSendCommand {
                account: Some("work".to_owned()),
                raw: b"From: Sender <sender@example.com>\r\nTo: Recipient <recipient@example.net>\r\nSubject: Hello\r\n\r\nBody\r\n".to_vec(),
            })
            .unwrap();
        std::fs::remove_file(path).ok();
        let (commands, data) = server.join().unwrap();

        assert!(result.sent);
        assert!(commands.iter().any(|command| command.starts_with("EHLO ")));
        assert!(commands.contains(&"MAIL FROM:<sender@example.com>".to_owned()));
        assert!(commands.contains(&"RCPT TO:<recipient@example.net>".to_owned()));
        assert!(data.contains("Subject: Hello"));
        assert!(data.contains("Body"));
    }

    fn write_config(content: &str) -> PathBuf {
        let unique = NEXT_TEMP_ID.fetch_add(1, Ordering::SeqCst);
        let path = env::temp_dir().join(format!("mailia-himalaya-config-{unique}.toml"));
        fs::write(&path, content).unwrap();
        path
    }

    fn temp_maildir_root() -> PathBuf {
        let unique = NEXT_TEMP_ID.fetch_add(1, Ordering::SeqCst);
        let path = env::temp_dir().join(format!("mailia-maildir-{unique}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn make_maildir(path: &Path) {
        fs::create_dir_all(path.join("cur")).unwrap();
        fs::create_dir_all(path.join("new")).unwrap();
        fs::create_dir_all(path.join("tmp")).unwrap();
    }

    fn write_maildir_message(root: &Path, relative_path: &str, subject: &str, date: &str) {
        let content = format!(
            "From: Sender <sender@example.com>\r\n\
             To: Recipient <recipient@example.net>\r\n\
             Subject: {subject}\r\n\
             Date: {date}\r\n\
             \r\n\
             Body\r\n"
        );
        write_maildir_raw_message(root, relative_path, content);
    }

    fn write_maildir_raw_message(root: &Path, relative_path: &str, content: impl AsRef<str>) {
        let path = root.join(relative_path);
        fs::write(path, content.as_ref()).unwrap();
    }
}
