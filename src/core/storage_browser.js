// Embedded by storage_browser.zig; negative results are stable bridge failures.
function (operation, key, ptr, len) {
    try {
        if (typeof localStorage === "undefined") return -1;
        if (operation === "check") {
            void localStorage.length;
            return 0;
        }
        if (operation === "size" || operation === "read") {
            const encoded = localStorage.getItem(key);
            if (encoded === null) return -5;
            if (operation === "size") {
                if (encoded.length > len) return -6;
                if (encoded.length % 4 !== 0) return -3;
                return encoded.length / 4 * 3;
            }
            const binary = atob(encoded);
            if (binary.length > len) return -4;
            for (let i = 0; i < binary.length; i++) HEAPU8[ptr + i] = binary.charCodeAt(i);
            return binary.length;
        }
        if (operation === "write") {
            let binary = "";
            for (let i = 0; i < len; i++) binary += String.fromCharCode(HEAPU8[ptr + i]);
            localStorage.setItem(key, btoa(binary));
            return 0;
        }
        if (operation === "remove") {
            if (localStorage.getItem(key) === null) return -5;
            localStorage.removeItem(key);
            return 0;
        }
        return -4;
    } catch (error) {
        if (error.name === "SecurityError") return -1;
        if (error.name === "QuotaExceededError") return -2;
        if (error.name === "InvalidCharacterError") return -3;
        return -4;
    }
}
