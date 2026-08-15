
export const KeyboardMetaKeyIcon = () => {
    if (navigator.platform.toUpperCase().indexOf('MAC') >= 0) {
        return <span className="text-sm">⌘</span>
    } else {
        return <span>Ctrl</span>
    }
}