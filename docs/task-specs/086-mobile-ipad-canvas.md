# Task 086: iPad canvas layout and a find-first start

Status: Active
Design: [RelayBar for iPhone and iPad](../designs/relaybar-ios.md)
Depends on: Task 085

## Outcome

On iPad the sidebar and the page always describe the same thing, and the app opens on a page built for finding one article or website.

Use on a real iPad showed the sidebar inside one folder while the page listed another, a phone list stretched across the page, hidden folders crowding the top, and a Markdown outline too narrow and too short to use. The person opens the app to find a specific article or website, so finding comes first.

## Delivery Boundary

Included: `Apps/RelayBarMobile`, with the iPhone changes named below.

Excluded: searching inside files, the transport, the web routes, plugin rules, and the Mac apps.

## Work

1. **One selection.** The iPad has a sidebar and one page. The sidebar holds Start, Places as a flat list, and Websites. Subfolders are reached on the page, not in the sidebar. The row marked in the sidebar is always the thing the page shows or, for a document, the folder that holds it. The sidebar has no location field and lists no files.
2. **Start.** The page shown for Start, from the top: a large search field; one Continue line for the last document read; Websites as tiles, pinned then open, each with a small picture of its page as last seen when there is one, and a tile that opens a port; Recent as up to six cards; Places as tiles. The app opens on Start, except that returning within ten minutes restores the page that was showing.
3. **Finding.** Typing in the search field replaces the page's content with results from the existing sources, in this order: a top hit, articles, websites, folders, hosts, and path completions when a path is typed. Return opens the top hit. Cancel restores the page. Command-K focuses the field from any page. Folder pages carry the same field.
4. **Folder page.** Path as segments, name, a line of counts, the search field, pin, order, a grid or list choice, and a menu. Then a Continue line when the last document read is in this folder; subfolders as tiles; and files as cards grouped by day ranges when ordered by date: documents with title, excerpt, date and file name; images as thumbnails; other kinds with a glyph. List is the dense form of the same items. Cards are created lazily and the existing 10,000-entry limit stands.
5. **Previews of unread documents.** For Markdown and text files on screen that have not been read, fetch the first 4 KiB at low priority to show a title and an excerpt, at most four at a time, cancelled when the card leaves the screen, cached by file stamp in the purgeable cache. With Data Saver on, none are fetched and the card shows the file name and Not Opened Yet.
6. **Reading.** A document takes the page. Its bar has the sidebar control, Back to the folder by name, previous and next within the folder with the position, the title over the file name, Rendered or Source, Open Beside, Share and Focus. Back returns the folder page to where it was scrolled.
7. **Outline.** Every heading level is listed, long headings wrap, rows are at least 40 points, the list scrolls, and the section being read is marked as the document scrolls, with the reading time left. On a page at least 1,000 points wide it is a rail 288 points wide beside the text. On a narrower iPad page it is a popover from the bar. On iPhone it stays a bottom panel with the same rows.
8. **Websites.** A website opens in the page with its own bar and can still be opened beside a document, which hides the sidebar as today. The picture on its tile is taken when its page is left, kept in the purgeable cache under the host's identity, and removed with the host or when the website is neither pinned nor open. The visible word is Websites wherever the app said Services or Web Services, on iPhone too.
9. **Hidden entries.** Names that begin with a dot are left out of folder pages and tiles, and counted in one last row with Show, which reveals them in that folder until it is left. This applies on iPhone too.
10. **Small corrections.** Home is titled Home. The iPad page that repeated the phone's Home, the sidebar's file rows and its location field are removed, not hidden.
11. **Gallery and specs.** The gallery covers Start, finding, a folder as cards and as a list, reading with the rail, reading with the popover, an image folder and a split page on iPad, and the hidden-items row and outline panel on iPhone, in both appearances. Update `docs/system-specs/modules/mobile-app.md` and add an iPad layout section to the design page.

## Acceptance

- Choosing any sidebar row changes the page to it, and opening any page marks its row; no state shows one folder in the sidebar and another on the page.
- A cold start shows Start with the search field; typing part of an article's title or a website's name lists it, and Return opens the top hit.
- A folder of Markdown files shows titles and excerpts for files never opened, and shows none when Data Saver is on.
- A document with four heading levels and forty headings shows all of them in the outline, scrollable, with the marked section following the scroll position.
- A folder holding dot-entries lists none of them until Show is used, and reports their number.
- Previous and next step through the folder in its shown order, and Back restores the folder page's scroll position.
- Unit tests cover the selection rule, the ten-minute restore rule, preview extraction and its cache and Data Saver rule, heading tracking, hidden-entry counting, and previous and next ordering.
- `scripts/test.sh mobile` passes, the app builds for the iOS SDK with warnings as errors, and the gallery images are regenerated and reviewed against the mock.
