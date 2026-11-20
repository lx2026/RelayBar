#if os(macOS)
  import AppKit
  import Composition
  import CompositionUI
  import CompositionFixtures
  import WebKit
  import HouseStyle
  import ImageIO
  import MobileCore
  import SwiftUI
  import UniformTypeIdentifiers

  public enum MobileGallery {
    @MainActor public static func write(to output: URL) async throws {
      QuietWindow.prepareTestProcess()
      let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let demo = try DemoHost()
      let core = try MobileComposition(
        directory: root, cache: root.appending(path: "cache"), keys: DemoKeys()
      ) {
        _, _, _ in demo
      }
      let profile = try await demo.install(in: core)
      do {
        try await render(core, demo, profile, output)
        await core.runtime.shutdown()
      } catch {
        await core.runtime.shutdown()
        try await removeTestStore(profile.id)
        throw error
      }
      try await removeTestStore(profile.id)
    }
    @MainActor private static func render(
      _ core: MobileComposition, _ demo: DemoHost, _ profile: Profile, _ output: URL
    ) async throws {
      core.runtime.service(Demand.self)?.show(profile.id, in: UUID())
      await core.runtime.settled()
      let deadline = ContinuousClock.now + .seconds(5)
      while core.runtime.service(Readers.self, realm: profile.realm) == nil,
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      guard let prefs = core.runtime.service(Profiles.self),
        let live = core.runtime.service(Readers.self, realm: profile.realm)
      else { throw CompositionError("The demo reader did not start.") }
      let workspace = HostWorkspace(
        core: core, profile: profile, profiles: prefs, initialRoute: nil,
        choose: { _ in }, resume: { _, _ in }, add: { _ in }, settings: {}, hosts: {})
      for name in ["monday-planning", "eval-protocol-v2", "check-in"] {
        _ = try await live.open(DemoHost.sessions + "/" + name + ".md")
      }
      _ = try await live.open(DemoHost.image)
      var study = try await live.open(DemoHost.article)
      study.position.heading = "Where layout exemplars help"
      try live.save(position: study.position, path: study.path)
      var data = prefs.value
      if let saver = MobileComposition.plugins.first(where: { $0.id == "data-saver" }) {
        data.set(saver, for: profile.id, enabled: false)
      }
      let report = try await live.open(DemoHost.report)
      let picture = try await live.open(DemoHost.image)
      guard let source = CGImageSourceCreateWithData(picture.file.data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw CocoaError(.fileReadCorruptFile) }
      let notebook = try await live.open(DemoHost.folder + "/study.ipynb")
      let table = try await live.open(DemoHost.folder + "/metrics.csv")
      let html = try await live.open(DemoHost.folder + "/eval.html")
      try prefs.update { $0 = data }
      var facts: [String: RowFacts] = [:]
      for directory in [
        DemoHost.folder, DemoHost.folder + "/samples", DemoHost.folder + "/notes",
        DemoHost.sessions,
      ] {
        let siblings = try demo.list(directory)
        for row in siblings {
          let path = (directory as NSString).appendingPathComponent(row.name)
          var fact = RowFacts(stamp: row.stamp)
          if row.stamp.directory {
            fact.count = try demo.list(path).count
          } else if imageFile(path),
            let bytes = try await live.thumbnail(path: path, stamp: row.stamp, limit: 2 << 20),
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)
          {
            fact.position = imagePosition(path, rows: siblings)
            fact.image = CGImageSourceCreateImageAtIndex(source, 0, nil)
          }
          if path.hasSuffix(".md") {
            fact.preview = DocumentPreview(
              String(decoding: try demo.read(path, limit: 65536), as: UTF8.self))
          }
          facts[path] = fact
        }
      }
      let folder = FolderScreen(
        workspace: workspace, path: DemoHost.folder, homePath: demo.home(), files: workspace.files,
        reader: live,
        limit: 2 << 20,
        history: data.history, actions: nil, open: { _ in }, rows: try demo.list(DemoHost.folder))
      func reader(
        _ doc: ReadDocument, page: CGImage? = nil, headings: [String] = [], internet: Bool? = nil
      ) -> ReaderScreen {
        ReaderScreen(
          path: doc.path, profile: profile, core: core, profiles: prefs,
          reader: workspace.readerPort,
          scriptPort: core.runtime.port(HTMLScripts.self, realm: profile.realm),
          files: workspace.files, galleryHeadings: headings, galleryInternet: internet,
          galleryImage: doc.isImage ? image : page, document: doc)
      }
      func chrome(_ view: some View, path: String, back: Bool = true, state: HostState = .connected)
        -> AnyView
      {
        AnyView(
          VStack(spacing: 0) {
            view.frame(maxWidth: .infinity, maxHeight: .infinity)
            if state == .connecting {
              Text("Saved copy from this session").secondaryText().padding(6).card()
            }
            LocationBar(host: profile.host, location: path, state: state, back: back ? {} : nil) {}
          })
      }
      let idle = Profile(host: "studio-mini", account: "reader")
      let failed = Profile(host: "archive", account: "reader")
      let galleryHosts = [profile, idle, failed]
      let states: [UUID: HostState] = [
        profile.id: .connected, idle.id: .idle,
        failed.id: .failed("Couldn’t reach archive. Check Tailscale is connected, then retry."),
      ]
      let services = data.pinnedServices?[profile.id] ?? []
      var tabData = data
      tabData.serviceTabs = [profile.id: services]
      try prefs.update { $0.set(networkPlugin, for: profile.id, enabled: true) }
      await core.runtime.settled()
      let composer = core.composer
      composer.selection = profile.realm + "/routes.network"
      let realmTitle: (String) -> String = { $0 == profile.realm ? profile.host : $0 }
      let endpoint = Destination(name: "dashboard", port: 8080)
      let sampleKey = try await core.runtime.service(Keys.self)?.key().authorizedKey ?? ""
      let logPath = DemoHost.folder + "/training.log"
      let log = String(decoding: try demo.read(logPath, limit: 65536), as: UTF8.self)
      let cacheSize = await core.cache.size(profile.id)
      let notes = DemoHost.folder + "/notes/sessions"
      let longFolder = FolderScreen(
        workspace: workspace, path: notes, homePath: demo.home(),
        files: workspace.files, reader: live, limit: workspace.thumbnailLimit,
        history: data.history,
        actions: nil, open: { _ in }, rows: try demo.list(notes))
      let completions = try await completePath("~/ru", nil, demo)
      guard let search = core.runtime.service(FileSearch.self, realm: profile.realm) else {
        throw CompositionError("The demo search did not start.")
      }
      let hits = await search.results("compar", visits: data.history, since: nil, waitForIndex: true)?.1 ?? []
      guard !hits.isEmpty else { throw CompositionError("The demo note was not indexed.") }
      func searchPage(_ status: String) -> AnyView {
        AnyView(
          GoPage(
            workspace: workspace, fromHome: true, hosts: galleryHosts, states: states,
            query: "compar", hits: hits, searchStatus: status))
      }
      let screens: [(String, AnyView)] = [
        (
          "Settings",
          AnyView(
            NavigationStack {
              SettingsContent(
                core: core, profiles: prefs, done: {}, key: sampleKey,
                sizes: [profile.id: cacheSize])
            })
        ),
        (
          "Plugins",
          AnyView(
            NavigationStack {
              MobilePluginsList(composer: composer, groupTitle: pluginGroup, realmTitle: realmTitle)
            })
        ),
        (
          "PluginDetail",
          AnyView(
            MobilePluginDetail(composer: composer, plugin: networkPlugin, realmTitle: realmTitle))
        ),
        (
          "PadPlugins",
          AnyView(
            MobilePluginsWorkspace(
              composer: composer, groupTitle: pluginGroup, realmTitle: realmTitle))
        ),
        (
          "DeleteConfirmation",
          AnyView(
            folder.bottomPanel(shown: true, fraction: 0.5) {
              DeleteConfirmation(path: DemoHost.folder + "/notes.txt", cancel: {}, confirm: {})
            })
        ),
        (
          "DeleteUndo",
          AnyView(
            VStack {
              folder
              DeletePanel(path: DemoHost.folder + "/notes.txt", submitted: false, undo: {})
            })
        ),
        ("LogFollow", AnyView(LogContent(path: logPath, content: log, paused: .constant(false)))),
        (
          "DestinationApproval",
          AnyView(
            workspace.home().bottomPanel(shown: true, fraction: 0.65) {
              ApprovalSheet(prompt: .destination(endpoint), host: profile.host, answer: { _ in })
            })
        ),
        (
          "CertificateApproval",
          AnyView(
            workspace.home().bottomPanel(shown: true, fraction: 0.65) {
              ApprovalSheet(
                prompt: .certificate(
                  .init(name: profile.privateName, port: 8443),
                  .init(subject: "Demo service", fingerprint: DemoHost.certificateFingerprint),
                  previous: nil), host: profile.host, answer: { _ in })
            })
        ),
        (
          "Hosts",
          AnyView(
            HostsPage(
              hosts: galleryHosts, history: data.history, states: states, query: .constant(""),
              connect: {}, settings: {}, choose: { _ in }))
        ),
        (
          "FirstConnection",
          AnyView(
            ConnectionSheet(
              host: profile.host, account: profile.account, prompt: .trust(DemoHost.identity),
              status: "", submitAccount: { _ in }, trust: { _ in }, submitPassword: { _, _ in },
              copyKey: {}, cancel: {}))
        ),
        (
          "Offer",
          AnyView(
            GeometryReader { geometry in
              VStack(alignment: .leading, spacing: 0) {
                Text("HTTP 403 · Forbidden").mobileFont(20, .semibold).padding(20)
                Spacer()
                LocalhostOffer(host: profile.host, title: "Notebooks", accept: {}, decline: {})
                  .frame(height: geometry.size.height * 0.65).clipShape(
                    RoundedRectangle(cornerRadius: 22))
              }.frame(maxWidth: .infinity, alignment: .leading).background(HouseColor.fill)
            })
        ),
        ("FileSearch", searchPage(NameIndex.progress(26))),
        ("FileSearchLimit", searchPage(NameIndex.limitNotice)),
        ("LongFolder", chrome(longFolder, path: displayPath(notes, home: demo.home()))),
        (
          "GoCompletion",
          AnyView(
            GoPage(
              workspace: workspace, fromHome: true, hosts: galleryHosts, states: states,
              query: "~/ru", completions: completions))
        ),
        ("Home", chrome(workspace.home(), path: "Open a path, port or host", back: false)),
        ("Folder", chrome(folder, path: displayPath(DemoHost.folder, home: demo.home()))),
        ("Image", chrome(reader(picture), path: (picture.path as NSString).lastPathComponent)),
        (
          "Go",
          AnyView(
            GoPage(workspace: workspace, fromHome: true, hosts: galleryHosts, states: states))
        ),
      ]
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try prefs.update { $0.serviceTabs = tabData.serviceTabs }
      for scheme in [ColorScheme.light, .dark] {
        var variants = screens
        let serviceImage = try await dashboardSnapshot(core, profile, demo, scheme)
        variants.append(
          (
            "Tabs",
            AnyView(
              OpenServices(
                hosts: [profile], data: tabData, states: states, current: profile.id,
                disconnect: {},
                preview: { _, address in
                  address.port == 6006
                    ? ServicePreview(image: serviceImage, route: "private name") : nil
                }, done: {}, new: {}, open: { _, _ in }, close: { _, _ in }))
          ))
        variants.append(
          (
            "Browser",
            AnyView(
              ZStack(alignment: .bottom) {
                Image(decorative: serviceImage, scale: 1).resizable()
                ServiceBar(
                  host: profile.host, port: 6006, count: services.count, state: .connected,
                  back: {}, go: {}, reload: {}, tabs: {}
                ) { Text("Page menu") }.serviceFade()
              })
          ))
        for (name, doc, selector) in [("Notebook", notebook, "h1"), ("Table", table, "th")] {
          let page = try await snapshot(
            doc, files: demo, scheme: scheme, selector: selector, height: 654)
          variants.append((name, chrome(reader(doc, page: page), path: doc.title)))
        }
        for allowed in [false, true] {
          let page = try await htmlSnapshot(html, files: demo, scheme: scheme, internet: allowed)
          variants.append(
            (
              allowed ? "HTML-allowed" : "HTML-blocked",
              chrome(reader(html, page: page, internet: allowed), path: html.title)
            ))
        }
        let outline = study.source.components(separatedBy: .newlines).filter { $0.hasPrefix("#") }
        let article = try await snapshot(
          study, files: demo, scheme: scheme, selector: "h3:nth-of-type(4)", height: 960, width: 823
        )
        let splitShot = try await snapshot(
          study, files: demo, scheme: scheme, selector: "h2:nth-of-type(2)", height: 960, width: 614
        )
        let wideService = try await dashboardSnapshot(
          core, profile, demo, scheme, width: 750, height: 960)
        let phoneArticle = try await snapshot(
          study, files: demo, scheme: scheme, selector: "h3:nth-of-type(4)", height: 654)
        var phoneOutline = reader(study, page: phoneArticle, headings: outline)
        phoneOutline.galleryOutline = true
        variants.append(("Outline", chrome(phoneOutline, path: study.title)))
        let hidden = FolderScreen(
          workspace: workspace, path: DemoHost.folder + "/samples", homePath: demo.home(),
          files: workspace.files, reader: live, limit: 2 << 20, history: data.history, actions: nil,
          open: { _ in }, rows: try demo.list(DemoHost.folder + "/samples"))
        variants.append(("HiddenItems", chrome(hidden, path: "samples")))
        for name in [
          "PadStart", "PadFind", "PadFolder", "PadFolderList", "PadReader", "PadOutline",
          "PadSplit", "PadImages", "PadImage",
        ] {
          let split = name == "PadSplit"
          let folderPage = ["PadFolder", "PadFolderList", "PadImages"].contains(name)
          let folderPath = name == "PadImages" ? DemoHost.folder + "/samples" : notes
          let route: Route? =
            ["PadStart", "PadFind"].contains(name)
            ? nil
            : folderPage
              ? .folder(folderPath) : .document(name == "PadImage" ? picture.path : study.path)
          let selection = PadSelection(
            primary: route, beside: split ? Route(kind: "service", path: ":6006") : nil)
          let folderPageView = FolderScreen(
            workspace: workspace, path: folderPath, homePath: demo.home(),
            files: workspace.files, reader: live, limit: 2 << 20, history: data.history,
            actions: nil,
            open: { _ in }, rows: try demo.list(folderPath), listOnPad: name == "PadFolderList")
          var document = reader(study, page: split ? splitShot : article, headings: outline)
          document.galleryOutline = name == "PadOutline"
          let primary: AnyView
          let findHits = await search.results("mon", visits: data.history, since: nil)?.1 ?? []
          if folderPage {
            primary = AnyView(folderPageView)
          } else if route == nil {
            primary = AnyView(
              PadStart(
                workspace: workspace, galleryPictures: [ServiceAddress(port: 6006): serviceImage],
                query: name == "PadFind" ? "mon" : "", hits: name == "PadFind" ? findHits : []))
          } else if name == "PadImage" {
            primary = AnyView(reader(picture))
          } else {
            primary = AnyView(document)
          }
          variants.append(
            (
              name,
              AnyView(
                PadWorkspace(
                  workspace: workspace, selection: .constant(selection),
                  pick: { _, _ in }, service: { _, _ in }
                ) {
                  primary
                } secondary: {
                  VStack(spacing: 0) {
                    PadServiceHeader(
                      title: "Run monitor", host: profile.host, port: 6006, back: {}, forward: {},
                      reload: {}, close: {}, route: "Direct")
                    Image(decorative: wideService, scale: 1).resizable()
                  }
                }.frame(maxWidth: name == "PadOutline" ? 1194 : .infinity))
            ))
        }
        for (name, selector) in [
          ("Document", "h1"), ("Document-table-code", "table"),
          ("Document-equation", ".math-display img.math"), ("Resume", "h1"),
        ] {
          let reconnecting = name == "Resume"
          let page = try await snapshot(
            report, files: demo, scheme: scheme, selector: selector,
            height: reconnecting ? 625 : 654)
          variants.append(
            (
              name,
              chrome(
                reader(report, page: page), path: (report.path as NSString).lastPathComponent,
                state: reconnecting ? .connecting : .connected)
            ))
        }
        for (name, view) in variants
        where ["Home", "LongFolder", "GoCompletion", "Folder", "Browser", "Offer", "Tabs", "Go"]
          .contains(name)
        {
          for (suffix, size) in [
            ("smallest", DynamicTypeSize.xSmall), ("largest", .accessibility5),
          ] {
            variants.append((name + "-" + suffix, AnyView(view.dynamicTypeSize(size))))
          }
        }
        for (name, view) in variants {
          let pad = name.hasPrefix("Pad")
          let width = pad ? 1376 : 390
          let height = pad ? 1032 : 844
          let sheet = name == "Offer" || name == "FirstConnection"
          let content = view.padding(.bottom, pad || sheet ? 0 : 30).background(
            name == "FirstConnection" ? HouseColor.panel : HouseColor.paper
          ).padding(.top, pad ? 24 : 62).frame(width: CGFloat(width), height: CGFloat(height))
            .background(HouseColor.paper).foregroundStyle(HouseColor.ink).buttonStyle(.plain)
            .textFieldStyle(.plain)
            .tint(MobileAccent.link).environment(\.colorScheme, scheme).environment(
              \.renderingGallery, true
            ).environment(\.galleryRows, facts)
          let renderer = ImageRenderer(content: content)
          renderer.scale = 1
          let file = output.appending(path: name + (scheme == .dark ? "-dark.png" : "-light.png"))
          let pixels: CGImage?
          let folderScreen = name.contains("Folder") || name.hasPrefix("Delete")
          if folderScreen || pad || name == "HiddenItems"
            || ["Plugins", "PadPlugins", "PluginDetail", "Settings", "LogFollow"].contains(name)
          {
            pixels = try await hosted(
              content, size: NSSize(width: width, height: height), scheme: scheme)
          } else {
            pixels = renderer.cgImage
          }
          guard let cg = pixels, cg.width == width, cg.height == height,
            let dest = CGImageDestinationCreateWithURL(
              file as CFURL, UTType.png.identifier as CFString, 1, nil)
          else { throw CompositionError("Could not render " + name) }
          CGImageDestinationAddImage(dest, cg, nil)
          guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        }
      }
    }
    @MainActor private static func hosted(_ content: some View, size: NSSize, scheme: ColorScheme)
      async throws -> CGImage?
    {
      let window = QuietWindow(size: size)
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let host = NSHostingView(rootView: content)
      window.contentView = host
      defer { window.contentView = nil }
      host.frame = NSRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(300))
      host.layoutSubtreeIfNeeded()
      guard
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width),
          pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { return nil }
      bitmap.size = size
      host.cacheDisplay(in: host.bounds, to: bitmap)
      return bitmap.cgImage
    }
    @MainActor private static func dashboardSnapshot(
      _ core: MobileComposition, _ profile: Profile,
      _ demo: DemoHost, _ scheme: ColorScheme, width: CGFloat = 390, height: CGFloat = 700
    ) async throws -> CGImage {
      let lease = try await core.routes.open(profile: profile, port: 6006, opener: demo)
      do {
        let window = QuietWindow(size: NSSize(width: width, height: height))
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let web = lease.makeView()
        window.contentView = web
        defer { window.contentView = nil }
        web.load(URLRequest(url: ServiceAddress(port: 6006).url(host: profile.privateName)!))
        let deadline = ContinuousClock.now + .seconds(15)
        while (try? await web.evaluateJavaScript("document.title") as? String) != "Run monitor" {
          guard ContinuousClock.now < deadline else {
            throw CompositionError("Dashboard did not load.")
          }
          try await Task.sleep(for: .milliseconds(30))
        }
        let image = try await web.takeSnapshot(configuration: nil)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
          throw CompositionError("Could not capture the demo dashboard.")
        }
        await core.routes.close(lease)
        return cg
      } catch {
        await core.routes.close(lease)
        throw error
      }
    }
    @MainActor private static func htmlSnapshot(
      _ doc: ReadDocument, files: DemoHost, scheme: ColorScheme, internet: Bool
    ) async throws -> CGImage {
      let page = try await HTMLPreview(
        path: doc.path, html: doc.source, files: files, scripts: true, internet: internet)
      let window = QuietWindow(size: NSSize(width: 390, height: 612))
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = page.web
      defer { window.contentView = nil }
      try await page.load()
      let deadline = ContinuousClock.now + .seconds(20)
      while (try? await page.web.evaluateJavaScript(
        "document.title === 'Template preferences' && document.images.length === 1 && document.images[0].complete"
      ) as? Bool) != true {
        guard ContinuousClock.now < deadline else {
          throw CompositionError("HTML report did not load.")
        }
        try await Task.sleep(for: .milliseconds(30))
      }
      let loaded = try await page.web.evaluateJavaScript("document.images[0].naturalWidth > 0")
      print(
        "HTML gallery: internet " + String(internet) + ", reference image loaded "
          + String(describing: loaded))
      guard loaded as? Bool == internet else {
        throw CompositionError("Reference image did not follow the internet permission.")
      }
      let image = try await page.web.takeSnapshot(configuration: nil)
      guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileReadUnknown)
      }
      return cg
    }
    @MainActor private static func snapshot(
      _ doc: ReadDocument, files: DemoHost, scheme: ColorScheme, selector: String, height: CGFloat,
      width: CGFloat = 390
    ) async throws -> CGImage {
      guard let html = doc.html else { throw CompositionError("Missing Markdown page.") }
      let handler = DocumentSchemeHandler(
        path: doc.path, html: "<!doctype html><meta charset=utf-8>" + html, files: files)
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.defaultWebpagePreferences.allowsContentJavaScript = false
      config.setURLSchemeHandler(handler, forURLScheme: "relay-document")
      let size = NSSize(width: width, height: height)
      let window = QuietWindow(size: size)
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
      window.contentView = web
      defer { window.contentView = nil }
      web.load(URLRequest(url: handler.scheme.mainURL))
      let deadline = ContinuousClock.now + .seconds(20)
      while true {
        let ready =
          try? await web.evaluateJavaScript(
            "document.readyState === 'complete' && !!document.querySelector('article')") as? Bool
        if ready == true { break }
        guard ContinuousClock.now < deadline else {
          throw CompositionError("Markdown page did not finish loading.")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      let located = try await web.callAsyncJavaScript(
        """
        await document.fonts.ready;
        const element = document.querySelector(selector);
        if (!element) return false;
        if (selector !== 'h1') element.scrollIntoView();
        return true;
        """, arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
      guard located as? Bool == true else {
        throw CompositionError("Missing Markdown element " + selector)
      }
      let image = try await web.takeSnapshot(configuration: nil)
      guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CompositionError("Could not snapshot Markdown.")
      }
      return pixels
    }
  }
#endif
