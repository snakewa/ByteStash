import { describe, expect, it } from 'vitest';
import { embedParentOrigin } from './embedUtils';

const win = (ancestorOrigins?: string[]) =>
  ({ location: { ancestorOrigins: ancestorOrigins && Object.assign([...ancestorOrigins], { item: (i: number) => ancestorOrigins[i], contains: () => false }) } }) as unknown as Pick<Window, 'location'>;

describe('embedParentOrigin', () => {
  it('prefers the first ancestor origin', () => {
    expect(embedParentOrigin(win(['https://blog.example', 'https://x.example']), 'https://other.example/page')).toBe('https://blog.example');
  });

  it('falls back to the referrer origin', () => {
    expect(embedParentOrigin(win(), 'https://blog.example/posts/1?a=b')).toBe('https://blog.example');
  });

  it('returns null when the parent is unknown', () => {
    expect(embedParentOrigin(win([]), '')).toBeNull();
    expect(embedParentOrigin(win(['null']), 'not a url')).toBeNull();
  });
});
