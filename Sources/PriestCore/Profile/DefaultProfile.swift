/// Built-in fallback default profile.
///
/// Used when the host application does not provide a 'default' profile directory.
/// Content is a spec-level constant — must match `behavior/profile-loading.md` exactly.
enum DefaultProfile {
    static let profile = Profile(
        name: "default",
        identity: "You are a helpful, thoughtful assistant.\n",
        rules: "Be honest. Do not make things up.\nBe concise unless the user asks for depth.\n",
        custom: "",
        memories: [],
        meta: [:]
    )
}
