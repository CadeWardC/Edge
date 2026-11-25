// Multiplayer transport. One player hosts and runs the simulation; the others connect to the
// host directly (WebRTC through PeerJS), so the game needs no game server of its own.
// With ?net=local in the URL, tabs of one browser connect over a BroadcastChannel instead,
// which is how the automated tests play multiplayer without the internet.
const PREFIX = 'warcamp-v1-';
const LETTERS = 'ABCDEFGHJKLMNPQRSTUVWXYZ';

export const LOCAL = new URLSearchParams(location.search).get('net') === 'local';
export const makeCode = () => Array.from({ length: 4 }, () => LETTERS[(Math.random() * LETTERS.length) | 0]).join('');

// A connection is { send(obj), close(), ondata, onclose }. A room is { onconn, close() }.
export function hostRoom(code) { return LOCAL ? bcHost(code) : peerHost(code); }
export function joinRoom(code) { return LOCAL ? bcJoin(code) : peerJoin(code); }

function wrap(dc, peer) {
  const c = { send: o => { if (dc.open) dc.send(o); }, close: () => { dc.close(); if (peer) peer.destroy(); }, ondata: null, onclose: null };
  let closed = false;
  const end = () => { if (!closed) { closed = true; if (c.onclose) c.onclose(); } };
  dc.on('data', d => c.ondata && c.ondata(d));
  dc.on('close', end);
  dc.on('error', end);
  return c;
}
function peerHost(code) {
  return new Promise((res, rej) => {
    if (!window.Peer) return rej(new Error('Multiplayer library did not load'));
    const peer = new window.Peer(PREFIX + code);
    const room = { onconn: null, close: () => peer.destroy() };
    let open = false;
    peer.on('open', () => { open = true; res(room); });
    peer.on('error', e => { if (!open) { peer.destroy(); rej(e); } });
    // The matchmaking link may drop mid-game; players already connected are not affected.
    peer.on('disconnected', () => { if (open && !peer.destroyed) setTimeout(() => { if (!peer.destroyed) peer.reconnect(); }, 3000); });
    peer.on('connection', dc => { const c = wrap(dc); dc.on('open', () => room.onconn && room.onconn(c)); });
  });
}
function peerJoin(code) {
  return new Promise((res, rej) => {
    if (!window.Peer) return rej(new Error('Multiplayer library did not load'));
    const peer = new window.Peer();
    const timer = setTimeout(() => { peer.destroy(); rej(new Error('No answer from room ' + code)); }, 15000);
    peer.on('error', e => { clearTimeout(timer); peer.destroy(); rej(e.type === 'peer-unavailable' ? new Error('Room ' + code + ' was not found') : e); });
    peer.on('open', () => {
      const dc = peer.connect(PREFIX + code, { reliable: true, serialization: 'json' });
      const c = wrap(dc, peer);
      dc.on('open', () => { clearTimeout(timer); res(c); });
    });
  });
}

function bcHost(code) {
  const bc = new BroadcastChannel(PREFIX + code), conns = new Map();
  const room = { onconn: null, close: () => { for (const id of conns.keys()) bc.postMessage({ to: id, k: 'close' }); bc.close(); } };
  bc.onmessage = ev => {
    const m = ev.data;
    if (m.to !== 'host') return;
    if (m.k === 'open') {
      const c = { send: o => bc.postMessage({ to: m.from, k: 'data', d: o }), close: () => { bc.postMessage({ to: m.from, k: 'close' }); conns.delete(m.from); }, ondata: null, onclose: null };
      conns.set(m.from, c);
      bc.postMessage({ to: m.from, k: 'ack' });
      if (room.onconn) room.onconn(c);
    } else {
      const c = conns.get(m.from);
      if (!c) return;
      if (m.k === 'data' && c.ondata) c.ondata(m.d);
      if (m.k === 'close') { conns.delete(m.from); if (c.onclose) c.onclose(); }
    }
  };
  return Promise.resolve(room);
}
function bcJoin(code) {
  return new Promise((res, rej) => {
    const bc = new BroadcastChannel(PREFIX + code), id = Math.random().toString(36).slice(2);
    const c = { send: o => bc.postMessage({ to: 'host', from: id, k: 'data', d: o }), close: () => { bc.postMessage({ to: 'host', from: id, k: 'close' }); bc.close(); }, ondata: null, onclose: null };
    const timer = setTimeout(() => { bc.close(); rej(new Error('Room ' + code + ' was not found')); }, 2000);
    bc.onmessage = ev => {
      const m = ev.data;
      if (m.to !== id) return;
      if (m.k === 'ack') { clearTimeout(timer); res(c); }
      if (m.k === 'data' && c.ondata) c.ondata(m.d);
      if (m.k === 'close' && c.onclose) c.onclose();
    };
    addEventListener('pagehide', () => c.close());
    bc.postMessage({ to: 'host', from: id, k: 'open' });
  });
}
