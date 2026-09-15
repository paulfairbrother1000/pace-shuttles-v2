// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';

const {loadAdminLiveOperationsDetail}=vi.hoisted(()=>({loadAdminLiveOperationsDetail:vi.fn(async()=>({data:[],error:null}))}));
vi.mock('@/lib/data',()=>({
 loadAdminLiveOperationsDetail,
 loadAdminJourneys:vi.fn(),
 loadOperators:vi.fn(),
 loadSettlements:vi.fn(),
}));

import {LiveOperations} from './dashboard';

afterEach(()=>{cleanup();loadAdminLiveOperationsDetail.mockClear()});

describe('LiveOperations scope',()=>{
 it('loads today onwards by default and offers useful date filters including past history',async()=>{
  render(<LiveOperations/>);
  await waitFor(()=>expect(loadAdminLiveOperationsDetail).toHaveBeenCalledWith('operational'));
  const scope=screen.getByLabelText('Journey scope');
  expect((scope as HTMLSelectElement).value).toBe('operational');
  expect(screen.getByRole('option',{name:'Today onwards'})).toBeTruthy();
  await userEvent.setup().selectOptions(scope,'today');
  await waitFor(()=>expect(loadAdminLiveOperationsDetail).toHaveBeenLastCalledWith('today'));
  await userEvent.setup().selectOptions(scope,'next_7_days');
  await waitFor(()=>expect(loadAdminLiveOperationsDetail).toHaveBeenLastCalledWith('next_7_days'));
  await userEvent.setup().selectOptions(scope,'past_closed');
  await waitFor(()=>expect(loadAdminLiveOperationsDetail).toHaveBeenLastCalledWith('past_closed'));
  expect(screen.getByRole('option',{name:'Past / closed'})).toBeTruthy();
 });
});
