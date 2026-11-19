export const profile = 'profiles/Agenticious';

/** Opens the presets page and goes back to whatever profile the deck was showing. */
export class DeckNavigation {
  constructor(switchProfile) {
    this.switchProfile = switchProfile;
    this.showing = new Set();
    /** Decks asked to go back that haven't said they left yet. */
    this.leaving = new Map();
  }

  /** The page's Back key says when it is on screen, however the deck got there. */
  visible(device, visible) {
    clearTimeout(this.leaving.get(device));
    this.leaving.delete(device);
    if (visible) this.showing.add(device); else this.showing.delete(device);
  }

  open(device) {
    if (!device || this.showing.has(device)) return;
    this.switchProfile(device, {profile});
  }

  /** An empty payload returns to the previous profile, so it is only sent from the page itself. The page counts as
   * showing until its Back key disappears: Stream Deck may have no profile to go back to, and then it stays. */
  home(device) {
    if (!this.showing.has(device) || this.leaving.has(device)) return;
    this.leaving.set(device, setTimeout(() => this.leaving.delete(device), 1000).unref());
    this.switchProfile(device, {});
  }
}
