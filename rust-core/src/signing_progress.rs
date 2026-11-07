//! Synchronous per-request callbacks, owned by the editor worker thread only.
use std::{cell::Cell, ffi::c_void};
pub type Callback = extern "C" fn(*mut c_void, u64, u64) -> i32;
#[derive(Clone, Copy)]
pub struct Sink { pub callback: Callback, pub context: usize }
thread_local! { static SINK: Cell<Option<Sink>> = const { Cell::new(None) }; }
pub fn scope<T>(sink: Option<Sink>, work: impl FnOnce() -> T) -> T {
    struct Reset(Option<Sink>);
    impl Drop for Reset { fn drop(&mut self) { SINK.with(|s| s.set(self.0)); } }
    let _reset = Reset(SINK.with(|s| s.replace(sink)));
    work()
}
/// Completed signed bundle units, not elapsed time or estimated bytes.
/// Checking at bundle boundaries also provides cooperative expiration handling.
pub fn report(done: usize, total: usize) -> Result<(), String> {
    SINK.with(|s| {
        if let Some(sink) = s.get() {
            if (sink.callback)(sink.context as *mut c_void, done as u64, total as u64) == 0 {
                return Err("انتهى وقت الخلفية. افتح Mirsa وجرّب التوقيع من جديد.".into());
            }
        }
        Ok(())
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    extern "C" fn accept(_: *mut c_void, done:u64, total:u64)->i32 { assert!(done <= total); 1 }
    extern "C" fn reject(_: *mut c_void, _:u64, _:u64)->i32 { 0 }
    #[test] fn scoped_cancel_and_restore() {
        assert!(scope(Some(Sink{callback:reject,context:0}),||report(0,4)).is_err());
        assert!(report(0,4).is_ok());
        scope(Some(Sink{callback:accept,context:0}),|| {
            assert!(report(1,4).is_ok());
            assert!(scope(Some(Sink{callback:reject,context:0}),||report(1,4)).is_err());
            assert!(report(4,4).is_ok());
        });
    }
    #[test] fn thread_local_does_not_leak_to_other_operations() {
        scope(Some(Sink{callback:reject,context:0}),|| {
            std::thread::spawn(|| assert!(report(0,1).is_ok())).join().unwrap();
            assert!(report(0,1).is_err());
        });
    }
    #[test] fn panic_restores_callback() {
        let _=std::panic::catch_unwind(||scope(Some(Sink{callback:reject,context:0}),||panic!("test")));
        assert!(report(0,1).is_ok());
    }
}
