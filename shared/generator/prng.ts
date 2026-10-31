// Générateur pseudo-aléatoire à graine fixe (mulberry32). Il ne sert qu'à produire
// les vecteurs : les apps lisent les JSON générés, jamais ce générateur.

export class Prng {
  private s: number;
  constructor(seed: number) {
    this.s = seed >>> 0;
  }
  /** Entier dans [0, 2^32). */
  next(): number {
    this.s = (this.s + 0x6d2b79f5) >>> 0;
    let t = this.s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (t ^ (t >>> 14)) >>> 0;
  }
  /** Entier dans [lo, hi]. */
  int(lo: number, hi: number): number {
    return lo + (this.next() % (hi - lo + 1));
  }
  chance(percent: number): boolean {
    return this.int(1, 100) <= percent;
  }
  shuffle<T>(xs: T[]): T[] {
    const a = [...xs];
    for (let i = a.length - 1; i > 0; i--) {
      const j = this.int(0, i);
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
  }
}
