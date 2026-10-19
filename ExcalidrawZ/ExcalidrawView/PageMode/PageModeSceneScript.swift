import Foundation

/// Runs each command against the live scene. No native scene copy is written back.
enum PageModeSceneScript {
    static let body = #"""
    const helper = window.excalidrawZHelper;
    const api = helper?._api;
    if (!api || helper.currentFileId !== expectedFileID) {
        throw new Error("The drawing changed. Open Pages again to continue.");
    }
    const command = JSON.parse(commandJSON);
    const all = api.getSceneElementsIncludingDeleted();
    const live = all.filter(element => !element.isDeleted);
    const metadata = frame => frame.customData?.excalidrawZPage;
    const pages = live.filter(element => element.type === "frame" && metadata(element)?.version === 1);
    const sceneOrder = new Map(pages.map((page, index) => [page.id, index]));
    const order = frame => Number.isFinite(metadata(frame).order) ? metadata(frame).order : sceneOrder.get(frame.id);
    pages.sort((left, right) => {
        const difference = order(left) - order(right);
        return Number.isNaN(difference) || difference === 0
            ? sceneOrder.get(left.id) - sceneOrder.get(right.id) : difference;
    });
    const describe = page => ({
        id: page.id,
        title: typeof page.name === "string" ? page.name : "",
        width: page.width,
        height: page.height,
        locked: page.locked === true,
    });
    const state = openedPageID => JSON.stringify({ pages: pages.map(describe), openedPageID });
    const getPage = () => {
        const page = pages.find(page => page.id === command.pageID);
        if (!page) throw new Error("This page is no longer available. Open Pages again.");
        return page;
    };
    const changesScene = ["add", "rename", "move", "remove"].includes(command.action);
    if (changesScene && api.getAppState().viewModeEnabled) {
        throw new Error("Leave view mode before changing pages.");
    }
    const assertEditable = page => {
        if (page.locked) throw new Error("Unlock the page frame before changing it.");
    };
    const pageData = (page, index) => ({
        ...page.customData,
        excalidrawZPage: { ...metadata(page), version: 1, order: index },
    });
    const capture = { captureUpdate: "IMMEDIATELY" };

    switch (command.action) {
        case "list":
            return state(null);
        case "add": {
            const { width, height } = command;
            if (![width, height].every(value => Number.isFinite(value) && value >= 100 && value <= 2000)) {
                throw new Error("The page size is not supported.");
            }
            // A circumscribed rectangle also clears rotated existing elements.
            let bottom = -80;
            for (const element of live) {
                const values = [element.x, element.y, element.width, element.height];
                if (!values.every(Number.isFinite)) throw new Error("The drawing has invalid element bounds.");
                const radius = Math.hypot(element.width, element.height) / 2;
                bottom = Math.max(bottom, element.y + element.height / 2 + radius);
            }
            const x = pages.length ? pages[pages.length - 1].x : 0;
            const y = bottom + 80;
            if (!Number.isFinite(y) || Math.abs(y) > 1e8) throw new Error("There is no space for another page here.");
            const created = helper.createElements([{ type: "frame", x, y, width, height, name: command.title || "" }]);
            if (created.length !== 1 || created[0].type !== "frame") throw new Error("The page could not be created.");
            const frame = created[0];
            const highestOrder = pages.reduce((highest, page) => Math.max(highest, Number.isFinite(order(page)) ? order(page) : 0), -1);
            frame.customData = { ...frame.customData, excalidrawZPage: { version: 1, order: highestOrder + 1 } };
            helper.addElements([frame], capture);
            pages.push(frame);
            return state(frame.id);
        }
        case "rename": {
            const page = getPage();
            assertEditable(page);
            const title = typeof command.title === "string" ? command.title.trim() : "";
            if (!title || title.length > 120) throw new Error("Use a page title with 1 to 120 characters.");
            helper.updateElements([{ id: page.id, updates: { name: title } }], capture);
            return JSON.stringify({ pages: pages.map(item => describe(item.id === page.id ? { ...item, name: title } : item)), openedPageID: null });
        }
        case "move": {
            const page = getPage();
            const index = pages.indexOf(page);
            if (command.offset !== -1 && command.offset !== 1) throw new Error("The page move is not supported.");
            const target = index + command.offset;
            if (target < 0 || target >= pages.length) return state(null);
            pages.forEach(assertEditable);
            pages.splice(index, 1);
            pages.splice(target, 0, page);
            helper.updateElements(pages.map((item, index) => ({ id: item.id, updates: { customData: pageData(item, index) } })), capture);
            return state(null);
        }
        case "remove": {
            const page = getPage();
            assertEditable(page);
            const children = all.filter(element => element.frameId === page.id);
            helper.updateElements([
                { id: page.id, updates: { isDeleted: true } },
                ...children.map(element => ({ id: element.id, updates: { frameId: null } })),
            ], capture);
            pages.splice(pages.indexOf(page), 1);
            return state(null);
        }
        case "open": {
            const page = getPage();
            helper.zoomToFitElements([page.id], { padding: 40 });
            return state(page.id);
        }
        case "canvas":
            helper.zoomToFit({ padding: 40 });
            return state(null);
        case "exportScene":
            return JSON.stringify({
                pages: pages.map(describe),
                scene: { elements: live, files: api.getFiles(), appState: { viewBackgroundColor: api.getAppState().viewBackgroundColor } },
            });
        default:
            throw new Error("The page action is not supported.");
    }
    """#
}
