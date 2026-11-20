/** Agenticious listens on this loopback port (`SessionStore.defaultPort`). */
export const defaultPort = 47821;

/** The running app, asked over its loopback server. Every call rejects when it isn't running or predates the plugin. */
export class Agenticious {
  constructor(port = defaultPort, request = fetch) {
    this.base = `http://127.0.0.1:${port}`;
    this.request = request;
  }

  /** The presets in their arranged order, each with the key image the app drew for it. */
  async presets() {
    const body = await this.json('/presets');
    if (!Array.isArray(body.presets)) throw new Error('Agenticious sent no presets');
    return body.presets.filter(preset => typeof preset.id === 'string' && typeof preset.image === 'string');
  }

  /** Opens the floating Summon window on a preset. */
  async summon(id) {
    const body = await this.json(`/summon/${encodeURIComponent(id)}`, 'POST');
    if (body.ok !== true) throw new Error(`Agenticious didn't open ${id}`);
  }

  async json(path, method = 'GET') {
    const response = await this.request(this.base + path, {method, signal: AbortSignal.timeout(1500)});
    if (response.status !== 200) throw new Error(`Agenticious answered ${response.status}`);
    return response.json();
  }
}
