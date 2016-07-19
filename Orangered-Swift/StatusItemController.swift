//
//  StatusItemController.swift
//  Orangered
//
//  Created by Alan Westbrook on 6/13/16.
//  Copyright © 2016 Rockwood Software. All rights reserved.
//

import Foundation
import Cocoa

private let kUpdateURL = URL(string: "http://voidref.com/orangered/version")
private let kRedditCookieURL = URL(string: "https://reddit.com")
private let kLoginMenuTitle = NSLocalizedString("Login…", comment: "Menu item title for bringing up the login window")
private let kLogoutMenuTitle = NSLocalizedString("Log Out", comment: "Menu item title for logging out")
private let kAttemptingLoginTitle = NSLocalizedString("Attempting Login…", comment: "Title of the login menu item while it's attemping to log in")
private let kOpenMailboxRecheckDelay = 5.0

class StatusItemController: NSObject, NSUserNotificationCenterDelegate {
    
    enum State {
        case loggedout
        case invalidcredentials
        case disconnected
        case mailfree
        case orangered
        case modmail
        case update
        
        private static let urlMap = [
            loggedout: nil,
            invalidcredentials: nil,
            disconnected: nil,
            mailfree: URL(string: "https://www.reddit.com/message/inbox/"),
            orangered: URL(string: "https://www.reddit.com/message/unread/"),
            modmail: URL(string: "https://www.reddit.com/message/moderator/"),
            update: nil
        ]
                
        func image(forAppearance appearanceName: String) -> NSImage {
            let imageMap = [
                loggedout: ["not-connected", "not-connected-dark"],
                invalidcredentials:  ["not-connected", "not-connected-dark"],
                disconnected: ["not-connected", "not-connected-dark"],
                mailfree: ["logged-in", "logged-in-dark"],
                orangered: ["message", "message-dark"],
                modmail: ["mod", "mod-dark"],
                update: ["BlueEnvelope", "BlueEnvelope"]
            ]

            let index = appearanceName == NSAppearanceNameVibrantDark ? 1 : 0
            
            guard let name = imageMap[self]?[index] else {
                fatalError("you really messed up this time, missing case: imageMap for \(self), index: \(index)")
            }
            
            guard let image = NSImage(named: name) else {
                fatalError("fix yo assets, missing image: \(name)")
            }
            
            return image
        }
        
        func mailboxUrl() -> URL? {
            return State.urlMap[self]!
        }
    }
    
    private var state = State.disconnected {
        willSet {
            if newValue != state {
                // In order to avoid having to set flags for handling values set that were already set, we check `willSet`. This, however, necessitates we reschedule handling until the value is actually set as there doesn't seem to be a way to let it set and then call a method synchronously
                DispatchQueue.main.async(execute: { 
                    self.handleStateChanged()
                })
            }
        }
    }
    
    private let statusItem = NSStatusBar.system().statusItem(withLength: NSSquareStatusItemLength)
    
    private var statusPoller:Timer?
    private let prefs = UserDefaults.standard
    private var statusConnection:URLSession?
    private let session = URLSession.shared
    private var loginWindowController:NSWindowController?
    private var prefWindowController:NSWindowController?
    private var mailboxItem:NSMenuItem?
    private var loginItem:NSMenuItem?
    private var mailCount = 0
    
    override init() {
        super.init()
        setup()
        if prefs.loggedIn {
            login()
        }
    }
    
    private func setup() {
        NSUserNotificationCenter.default.delegate = self
        setupMenu()
    }
    
    private func setupMenu() {
        let menu = Menu()
        
        let mailbox = NSMenuItem(title: NSLocalizedString("Mailbox…", comment:"Menu item for opening the reddit mailbox"), 
                                 action: #selector(handleMailboxItemSelected), keyEquivalent: "")
        mailbox.isEnabled = false
        menu.addItem(mailbox)
        menu.addItem(NSMenuItem.separator())

        mailboxItem = mailbox
        
        let login = NSMenuItem(title: kLoginMenuTitle, 
                               action: #selector(handleLoginItemSelected), keyEquivalent: "")
        menu.addItem(login)
        loginItem = login

#if PrefsDone
        let prefsItem = NSMenuItem(title: NSLocalizedString("Preferences…", comment:"Menu item title for opening the preferences window"),
                                   action: #selector(handlePrefItemSelected), keyEquivalent: "")
        menu.addItem(prefsItem)
#endif
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: NSLocalizedString("Quit", comment:"Quit menu item title"), 
                                  action: #selector(quit), keyEquivalent: "")
        menu.addItem(quitItem)
        
        menu.items.forEach { (item) in
            item.target = self
        }
        
        statusItem.menu = menu
        statusItem.alternateImage = NSImage(named: "active")
        updateIcon()
    }
    
    private func login() {
        guard let url = URL(string: "https://ssl.reddit.com/api/login") else {
            print("Error bad url, wat?")
            return
        }
        
        guard let uname = prefs.username, let password = prefs.password else {
            showLoginWindow()
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "user=\(uname)&passwd=\(password)".data(using: String.Encoding.utf8)

        loginItem?.title = kAttemptingLoginTitle
        
        let task = session.dataTask(with: request) { (data, response, error) in
            self.handleLogin(response: response as? HTTPURLResponse, data:data, error: error)
        }
        
        task.resume()
    }
    
    private func handleLogin(response:HTTPURLResponse?, data:Data?, error:NSError?) {
        if let dataActual = data, let 
               dataString = String(data:dataActual, encoding:String.Encoding.utf8) {
            if dataString.contains("wrong password") {
                // TODO: wrong password error
                print("Wrong password")
                return
            }
        }
        
        guard let headers = response?.allHeaderFields as? [String:String] else {
            print("wrong headers ... or so: \(response?.allHeaderFields)")
            return
        }
        
        guard let url = response?.url else {
            print("missing url from response: \(response)")
            return
        }
        
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        
        if cookies.count < 1 {
            print("Login error: \(response)")
            state = .disconnected
        }
        else {
            HTTPCookieStorage.shared.setCookies(cookies, for: kRedditCookieURL, mainDocumentURL: nil)
            
            prefs.loggedIn = true
            state = .mailfree
            setupStatusPoller()
        }
    }
    
    private func setupStatusPoller() {
        statusPoller?.invalidate()
        let interval:TimeInterval = 60
        statusPoller = Timer(timeInterval: interval, target: self, selector: #selector(checkReddit), userInfo: nil, repeats: true)
        RunLoop.main.add(statusPoller!, forMode: RunLoopMode.defaultRunLoopMode)
        statusPoller?.fire()
    }
    
    private func showLoginWindow() {
        let login = LoginViewController { [weak self] (name, password) in
            self?.loginWindowController?.close()
            self?.prefs.username = name
            self?.prefs.password = password
            self?.login()
        }
        
        let window = NSPanel(contentViewController: login)
        window.appearance = NSAppearance(named: NSAppearanceNameVibrantLight)
        loginWindowController = NSWindowController(window: window)
        
        NSApp.activateIgnoringOtherApps(true)
        loginWindowController?.showWindow(self)
    }
    
    private func showPrefWindow() {
        let pref = NSWindowController(window: NSPanel(contentViewController: PrefViewController()))
        
        prefWindowController = pref
        NSApp.activateIgnoringOtherApps(true)
        pref.showWindow(self)
    }
    
    private func interpretResponse(json: AnyObject) {
        // Crude, but remarkably immune to data restructuring as long as the key value pairs don't change.

        guard let jsonActual = json["data"] as? [String:AnyObject] else {
            print("response json unexpected format: \(json)")
            return
        }
        
        if let newMailCount = jsonActual["inbox_count"] as? Int {
            if newMailCount != mailCount {
                mailCount = newMailCount
                
                if mailCount > 0 {
                    notifyMail()
                }
            }
        }
        
        if let modMailState = jsonActual["has_mod_mail"] as? Bool, modMailState == true {
            state = .modmail
            return
        }

        if let mailState = jsonActual["has_mail"] as? Bool {
            if mailState {
                state = .orangered
            }
            else {
                state = .mailfree
            }
        }
        else {
            // probably login error
            state = .disconnected
        }        
    }
    
    private func handleStateChanged() {
        updateIcon()
        mailboxItem?.isEnabled = true
        loginItem?.title = prefs.loggedIn ? kLogoutMenuTitle : kLoginMenuTitle
        
        switch state {
            case .orangered, .modmail:
                notifyMail()
                
            case .disconnected:
                DispatchQueue.main.after(when: DispatchTime.now() + 10, execute: { 
                    self.login()
                })
            fallthrough
            case .loggedout, .invalidcredentials:
                mailboxItem?.isEnabled = false
                
            
            case .mailfree, .update:
                break
        }
    }
    
    private func updateIcon() {
        statusItem.image = state.image(forAppearance: statusItem.button!.effectiveAppearance.name)
    }
    
    private func notifyMail() {
        let note = NSUserNotification()
        note.title                  = "Orangered!"
        note.informativeText        = NSLocalizedString("You have a new message on reddit!", comment: "new message notification text")
        note.actionButtonTitle      = NSLocalizedString("Read", comment: "notification call to action button")
        
        if mailCount > 1 {
            // Note: This localization is not going to work...
            note.informativeText = NSLocalizedString("You have \(mailCount) unread messages on reddit", comment: "plural message notification text")
        }
        
        NSUserNotificationCenter.default.deliver(note)
    }
    
    private func openMailbox() {    
        if let url = state.mailboxUrl() {
            NSWorkspace.shared().open(url)
        }
        
        DispatchQueue.main.after(when: DispatchTime.now() + kOpenMailboxRecheckDelay) { 
            self.checkReddit()
        }
        
        NSUserNotificationCenter.default.removeAllDeliveredNotifications()
    }
    
    private func logout() {
        prefs.loggedIn = false
        statusPoller?.invalidate()
        let storage = HTTPCookieStorage.shared 
        storage.cookies(for: kRedditCookieURL!)?.forEach { storage.deleteCookie($0) }
        state = .loggedout
    }
    
    @objc private func checkReddit() {
        guard let uname = prefs.username,
            let url = URL(string: "http://www.reddit.com/user/\(uname)/about.json") else {
                print("User name empty")
                return
        }

        let task = session.dataTask(with: url) { (data, response, error) in
            if let dataActual = data {
                do {
                    try self.interpretResponse(json: JSONSerialization.jsonObject(with: dataActual, options: .allowFragments))
                } catch let error {
                    print("Error reading response json: \(error)")
                }
            }
            else {
                print("Failure: \(response)")
            }
        }
        
        task.resume()
    }
    
    @objc private func quit() {
        NSApplication.shared().stop(nil)
    }
    
    @objc func handleLoginItemSelected() {
        if prefs.loggedIn {
            logout()
        }
        else {
            showLoginWindow()
        }
    }
    
    @objc func handlePrefItemSelected() {
        showPrefWindow()
    }
    
    @objc func handleMailboxItemSelected() {
        openMailbox()
    }
    
    
    // MARK: User Notification Center
    
    @objc func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        openMailbox()
    }
}

