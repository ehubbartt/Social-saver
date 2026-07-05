import Foundation

// Copy this file to SupabaseConfig.swift (same folder) and fill in the values
// from your Supabase project dashboard (Settings -> API).
// SupabaseConfig.swift is gitignored so credentials never land in the repo.
enum SupabaseConfig {
    static let url = URL(string: "https://YOUR-PROJECT-REF.supabase.co")!
    static let anonKey = "YOUR-ANON-KEY"

    /// Must match the app group in project.yml and both entitlements files.
    static let appGroup = "group.com.ehubbartt.socialsaver"

    /// Shared keychain access group so the app and the share extension see the
    /// same auth session. The AppIdentifierPrefix is resolved at runtime.
    static let keychainAccessGroup = "com.ehubbartt.socialsaver.shared"
}
