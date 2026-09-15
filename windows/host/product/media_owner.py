"""One media owner for both desktop and XR, confined to the backend event loop."""
class MediaOwner:
    def __init__(self):
        self.mode='idle';self.device_id=None;self.token=None;self.failed=False

    def claim(self,mode,device_id):
        if mode not in ('desktop','focus') or self.failed or self.token is not None:
            raise ValueError('Media is unavailable or already owned')
        token=object();self.mode=mode;self.device_id=device_id;self.token=token
        return token

    def release(self,token,clean=True):
        if token is not self.token:raise RuntimeError('Media ownership mismatch')
        self.failed=not clean;self.mode='idle' if clean else 'failed'
        self.device_id=None;self.token=None
