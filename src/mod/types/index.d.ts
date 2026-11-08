export type AvatarName = string

declare module 'claude-code' {
  interface PluginState {
    'desk-buddy': { avatar: AvatarName | null }
  }
}
