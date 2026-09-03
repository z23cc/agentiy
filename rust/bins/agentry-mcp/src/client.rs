//! Thin framed client used by tests and as a smoke helper for the Rust host.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use agentry_proto::agent_host::v1::{
    self, AgentSessionSnapshot, ClientMessage, CommandRequest, CommandResponse, EventNotification,
    HandshakeRejected, Hello, HostMessage, HostNotice, ResnapshotRequired, Welcome,
};
use agentry_proto::agent_host::{
    FRAME_LENGTH_PREFIX_BYTES, decode_host_message, encode_client_message, encode_snapshot,
    frame_payload_length,
};

use crate::HostError;

pub struct AgentHostClient {
    stream: UnixStream,
}

#[derive(Debug)]
pub enum HandshakeOutcome {
    Welcome(Welcome),
    Rejected(HandshakeRejected),
}

#[derive(Debug, Default)]
pub struct CommandRoundtrip {
    pub response: Option<CommandResponse>,
    pub events: Vec<EventNotification>,
    pub snapshots: Vec<AgentSessionSnapshot>,
    pub resnapshots: Vec<ResnapshotRequired>,
    pub notices: Vec<HostNotice>,
}

impl AgentHostClient {
    pub fn connect(socket: &Path) -> Result<Self, HostError> {
        let stream = UnixStream::connect(socket)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        Ok(Self { stream })
    }

    pub fn hello(&mut self, hello: Hello) -> Result<HandshakeOutcome, HostError> {
        self.write_client(v1::client_message::Body::Hello(hello))?;
        match self.read_host()?.body {
            Some(v1::host_message::Body::Welcome(welcome)) => {
                Ok(HandshakeOutcome::Welcome(welcome))
            }
            Some(v1::host_message::Body::HandshakeRejected(rejected)) => {
                Ok(HandshakeOutcome::Rejected(rejected))
            }
            other => Err(HostError::Protocol(format!(
                "expected welcome or reject, got {other:?}"
            ))),
        }
    }

    pub fn command(&mut self, request: CommandRequest) -> Result<CommandRoundtrip, HostError> {
        let request_id = request.request_id.clone();
        self.write_client(v1::client_message::Body::Command(request))?;
        let mut trip = CommandRoundtrip::default();
        let mut snapshot_bytes = Vec::new();
        loop {
            let message = self.read_host()?;
            match message.body {
                Some(v1::host_message::Body::Response(response)) => {
                    if response.request_id == request_id {
                        trip.response = Some(response);
                        break;
                    }
                }
                Some(v1::host_message::Body::Event(event)) => trip.events.push(event),
                Some(v1::host_message::Body::SnapshotBegin(_)) => snapshot_bytes.clear(),
                Some(v1::host_message::Body::SnapshotChunk(chunk)) => {
                    snapshot_bytes.extend_from_slice(&chunk.data);
                }
                Some(v1::host_message::Body::SnapshotEnd(_)) => {
                    if !snapshot_bytes.is_empty() {
                        if let Ok(snapshot) =
                            agentry_proto::agent_host::decode_snapshot(&snapshot_bytes)
                        {
                            trip.snapshots.push(snapshot);
                        }
                    }
                    snapshot_bytes.clear();
                }
                Some(v1::host_message::Body::ResnapshotRequired(required)) => {
                    trip.resnapshots.push(required);
                }
                Some(v1::host_message::Body::Notice(notice)) => trip.notices.push(notice),
                Some(
                    v1::host_message::Body::Welcome(_)
                    | v1::host_message::Body::HandshakeRejected(_),
                )
                | None => {}
            }
        }
        // Attach sends the response first, then snapshot + replay. Drain the tail.
        while let Ok(Some(message)) = self.try_read_host() {
            match message.body {
                Some(v1::host_message::Body::Event(event)) => trip.events.push(event),
                Some(v1::host_message::Body::SnapshotBegin(_)) => snapshot_bytes.clear(),
                Some(v1::host_message::Body::SnapshotChunk(chunk)) => {
                    snapshot_bytes.extend_from_slice(&chunk.data);
                }
                Some(v1::host_message::Body::SnapshotEnd(_)) => {
                    if let Ok(snapshot) =
                        agentry_proto::agent_host::decode_snapshot(&snapshot_bytes)
                    {
                        trip.snapshots.push(snapshot);
                    }
                    snapshot_bytes.clear();
                }
                Some(v1::host_message::Body::ResnapshotRequired(required)) => {
                    trip.resnapshots.push(required);
                }
                Some(v1::host_message::Body::Notice(notice)) => trip.notices.push(notice),
                _ => {}
            }
        }
        if trip.response.is_none() {
            return Err(HostError::Protocol(
                "command produced no response".to_string(),
            ));
        }
        Ok(trip)
    }

    pub fn wait_message(&mut self, timeout: Duration) -> Result<Option<HostMessage>, HostError> {
        self.stream.set_read_timeout(Some(timeout))?;
        match self.read_host() {
            Ok(message) => Ok(Some(message)),
            Err(HostError::Io(error))
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock =>
            {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    fn try_read_host(&mut self) -> Result<Option<HostMessage>, HostError> {
        self.stream
            .set_read_timeout(Some(Duration::from_millis(50)))?;
        match self.read_host() {
            Ok(message) => Ok(Some(message)),
            Err(HostError::Io(error))
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock =>
            {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    fn write_client(&mut self, body: v1::client_message::Body) -> Result<(), HostError> {
        let frame = encode_client_message(&ClientMessage { body: Some(body) })?;
        self.stream.write_all(&frame)?;
        Ok(())
    }

    fn read_host(&mut self) -> Result<HostMessage, HostError> {
        read_host_frame(&mut self.stream)
    }
}

pub fn read_host_frame(stream: &mut UnixStream) -> Result<HostMessage, HostError> {
    let mut prefix = [0u8; FRAME_LENGTH_PREFIX_BYTES];
    stream.read_exact(&mut prefix)?;
    let length = frame_payload_length(&prefix)?;
    let mut payload = vec![0u8; length];
    stream.read_exact(&mut payload)?;
    let mut frame = prefix.to_vec();
    frame.append(&mut payload);
    Ok(decode_host_message(&frame)?)
}

pub fn read_client_frame(stream: &mut UnixStream) -> Result<ClientMessage, HostError> {
    let mut prefix = [0u8; FRAME_LENGTH_PREFIX_BYTES];
    stream.read_exact(&mut prefix)?;
    let length = frame_payload_length(&prefix)?;
    let mut payload = vec![0u8; length];
    stream.read_exact(&mut payload)?;
    let mut frame = prefix.to_vec();
    frame.append(&mut payload);
    Ok(agentry_proto::agent_host::decode_client_message(&frame)?)
}

pub fn write_host_frame(stream: &mut UnixStream, message: &HostMessage) -> Result<(), HostError> {
    let frame = agentry_proto::agent_host::encode_host_message(message)?;
    stream.write_all(&frame)?;
    Ok(())
}

pub fn write_client_frame(
    stream: &mut UnixStream,
    message: &ClientMessage,
) -> Result<(), HostError> {
    let frame = encode_client_message(message)?;
    stream.write_all(&frame)?;
    Ok(())
}

/// Kept so tests can hash a snapshot the same way the host does.
#[must_use]
pub fn snapshot_byte_length(snapshot: &AgentSessionSnapshot) -> Result<usize, HostError> {
    Ok(encode_snapshot(snapshot)?.len())
}
