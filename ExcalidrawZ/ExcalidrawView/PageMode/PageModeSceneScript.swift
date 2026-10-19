import Foundation

/// Runs each command against the live scene. No native scene copy is written back.
enum PageModeSceneScript {
    static let body = #"""
    const helper = window.excalidrawZHelper;
    const api = helper?._api;
    if (!api || helper.currentFileId !== expectedFileID) {
        throw new Error("documentChanged");
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
        if (!page) throw new Error("pageMissing");
        return page;
    };
    const changesScene = ["add", "rename", "move", "remove"].includes(command.action);
    if (changesScene && api.getAppState().viewModeEnabled) {
        throw new Error("viewMode");
    }
    const assertEditable = page => {
        if (page.locked) throw new Error("pageLocked");
    };
    const pageData = (page, index) => ({
        ...page.customData,
        excalidrawZPage: { ...metadata(page), version: 1, order: index },
    });
    const capture = { captureUpdate: "IMMEDIATELY" };
    const cameraOptions = { animate: false, canvasOffsets: { top: 40, right: 40, bottom: 40, left: 40 } };
    // Keep the live objects intact until updateScene captures the undo change.
    const updatePages = patches => {
        const updates = new Map(patches.map(patch => [patch.id, patch.updates]));
        const elements = all.map(element => {
            if (!updates.has(element.id)) return element;
            const copy = { ...element };
            api.mutateElement(copy, updates.get(element.id), false);
            return copy;
        });
        api.updateScene({ elements, ...capture });
    };

    switch (command.action) {
        case "list":
            return state(null);
        case "add": {
            const { width, height } = command;
            if (![width, height].every(value => Number.isFinite(value) && value >= 100 && value <= 2000)) {
                throw new Error("invalidSize");
            }
            // A circumscribed rectangle also clears rotated existing elements.
            let bottom = -80;
            for (const element of live) {
                const values = [element.x, element.y, element.width, element.height];
                if (!values.every(Number.isFinite)) throw new Error("invalidBounds");
                const radius = Math.hypot(element.width, element.height) / 2;
                bottom = Math.max(bottom, element.y + element.height / 2 + radius);
            }
            const x = pages.length ? pages[pages.length - 1].x : 0;
            const y = bottom + 80;
            if (!Number.isFinite(y) || Math.abs(y) > 1e8) throw new Error("noSpace");
            const created = helper.createElements([{ type: "frame", x, y, width, height, name: command.title || "", children: [] }]);
            if (created.length !== 1 || created[0].type !== "frame") throw new Error("failedAction");
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
            if (!title || title.length > 120) throw new Error("invalidTitle");
            updatePages([{ id: page.id, updates: { name: title } }]);
            return JSON.stringify({ pages: pages.map(item => describe(item.id === page.id ? { ...item, name: title } : item)), openedPageID: null });
        }
        case "move": {
            const page = getPage();
            const index = pages.indexOf(page);
            if (command.offset !== -1 && command.offset !== 1) throw new Error("invalidMove");
            const target = index + command.offset;
            if (target < 0 || target >= pages.length) return state(null);
            pages.forEach(assertEditable);
            pages.splice(index, 1);
            pages.splice(target, 0, page);
            updatePages(pages.map((item, index) => ({ id: item.id, updates: { customData: pageData(item, index) } })));
            return state(null);
        }
        case "remove": {
            const page = getPage();
            assertEditable(page);
            const children = all.filter(element => element.frameId === page.id);
            updatePages([
                { id: page.id, updates: { isDeleted: true } },
                ...children.map(element => ({ id: element.id, updates: { frameId: null } })),
            ]);
            pages.splice(pages.indexOf(page), 1);
            return state(null);
        }
        case "open": {
            const page = getPage();
            helper.zoomToFitElements([page.id], cameraOptions);
            return state(page.id);
        }
        case "canvas":
            helper.zoomToFit(cameraOptions);
            return state(null);
        case "exportScene":
            return JSON.stringify({
                pages: pages.map(describe),
                scene: { elements: live, files: api.getFiles(), appState: { viewBackgroundColor: api.getAppState().viewBackgroundColor } },
            });
        default:
            throw new Error("failedAction");
    }
    """#
}
