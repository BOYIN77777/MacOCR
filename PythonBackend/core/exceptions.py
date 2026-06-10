class MacOCRException(Exception):
    pass


class ModelNotAvailableError(MacOCRException):
    def __init__(self):
        super().__init__("OCR models are not available. Download them first.")


class InvalidFileError(MacOCRException):
    def __init__(self, path: str, reason: str = ""):
        self.path = path
        super().__init__(f"Invalid file: {path}" + (f" - {reason}" if reason else ""))


class OCRProcessingError(MacOCRException):
    def __init__(self, page: int, detail: str):
        self.page = page
        super().__init__(f"Error on page {page}: {detail}")
